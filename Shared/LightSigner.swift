import Foundation
import os.log

private let logger = Logger(subsystem: "dev.nostr.clave", category: "signer")

enum LightSigner {

    struct RequestResult {
        let method: String
        let eventKind: Int?
        let clientPubkey: String
        let status: String          // "signed", "blocked", "pending", "error", "skipped-duplicate"
        let errorMessage: String?
        /// Set when status == "pending" so callers can schedule a UNNotificationRequest
        /// with a stable identifier matching the queued PendingRequest.id.
        /// nil for all other statuses.
        var pendingRequestId: String? = nil
        /// Hex id of the resulting signed event. Set only for successful
        /// `sign_event` results; nil otherwise. Forwarded into ActivityEntry
        /// to power the njump deep link in the activity detail view.
        var signedEventId: String? = nil
        /// One-line summary of what was signed, derived at sign-time from
        /// kind + tags via `ActivitySummary.signedSummary`. Forwarded into
        /// ActivityEntry verbatim.
        var signedSummary: String? = nil
    }

    static func handleRequest(
        privateKey: Data,
        requestEvent: [String: Any],
        skipProtection: Bool = false,
        responseRelays: [LightRelay]? = nil,
        responseRelayUrl: String? = nil
    ) async throws -> RequestResult {
        guard let senderPubkey = requestEvent["pubkey"] as? String,
              let encryptedContent = requestEvent["content"] as? String else {
            logger.error("[LightSigner] Invalid event: missing pubkey or content")
            return RequestResult(method: "unknown", eventKind: nil, clientPubkey: "unknown",
                                 status: "error", errorMessage: "Invalid event")
        }

        // Per-event-id dedupe (audit D.1.1). Both NSE and the foreground
        // relay subscription (Layer 1) call into this function; whichever
        // marks first wins, others skip. Cross-process semantics are lossy
        // by design — see SharedStorage.markEventProcessed.
        let eventId = (requestEvent["id"] as? String) ?? ""
        let createdAt = (requestEvent["created_at"] as? Double)
            ?? Double(requestEvent["created_at"] as? Int ?? 0)
        let nowFallback = Date().timeIntervalSince1970
        if !eventId.isEmpty,
           SharedStorage.markEventProcessed(
               eventId: eventId,
               createdAt: createdAt > 0 ? createdAt : nowFallback
           ) == .alreadyProcessed {
            logger.notice("[LightSigner] skip dedup eid=\(eventId.prefix(8), privacy: .public)")
            return RequestResult(
                method: "deduped", eventKind: nil, clientPubkey: senderPubkey,
                status: "skipped-duplicate", errorMessage: nil
            )
        }

        guard let senderPubkeyData = Data(hexString: senderPubkey) else {
            logger.error("[LightSigner] Invalid sender pubkey hex")
            return RequestResult(method: "unknown", eventKind: nil, clientPubkey: senderPubkey,
                                 status: "error", errorMessage: "Invalid sender pubkey")
        }

        let isNip04 = encryptedContent.contains("?iv=")
        let decrypted: String
        do {
            decrypted = try LightCrypto.decrypt(
                privateKey: privateKey,
                publicKey: senderPubkeyData,
                payload: encryptedContent
            )
        } catch {
            logger.error("[LightSigner] Decrypt failed: \(error.localizedDescription, privacy: .public)")
            let result = RequestResult(method: "unknown", eventKind: nil, clientPubkey: senderPubkey,
                                       status: "error", errorMessage: "Decrypt failed")
            logAndTrack(result: result)
            return result
        }

        guard let data = decrypted.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requestId = json["id"] as? String,
              let method = json["method"] as? String else {
            logger.error("[LightSigner] Failed to parse JSON-RPC")
            let result = RequestResult(method: "unknown", eventKind: nil, clientPubkey: senderPubkey,
                                       status: "error", errorMessage: "Invalid JSON-RPC")
            logAndTrack(result: result)
            return result
        }

        let params = json["params"] as? [String] ?? []
        logger.notice("[LightSigner] Method: \(method, privacy: .public)")

        // Extract event kind for sign_event
        let eventKind = extractEventKind(method: method, params: params)

        // Extract client name for connect
        let clientName = (method == "connect" && !params.isEmpty) ? extractConnectName(params: params) : nil

        // --- Per-client permission checks ---
        if method == "connect" {
            // connect params: [remote-signer-pubkey, optional-secret, optional-perms]
            let providedSecret = params.count >= 2 ? params[1] : ""
            let expectedSecret = SharedStorage.getBunkerSecret()

            if !providedSecret.isEmpty && providedSecret == expectedSecret {
                // Valid secret — check cap before creating new permissions
                let isExistingClient = SharedStorage.getClientPermissions(for: senderPubkey) != nil
                if !isExistingClient {
                    let currentCount = SharedStorage.getConnectedClients().count
                    if currentCount >= 5 {
                        logger.notice("[LightSigner] Bunker connect rejected: pairing cap reached (5)")
                        let result = RequestResult(
                            method: method, eventKind: nil, clientPubkey: senderPubkey,
                            status: "blocked", errorMessage: "Pairing limit reached (5)"
                        )
                        logAndTrack(result: result, clientName: clientName)
                        try await sendErrorResponse(
                            requestId: requestId,
                            error: "Pairing limit reached. Unpair an existing client in Clave settings.",
                            privateKey: privateKey, senderPubkeyData: senderPubkeyData,
                            senderPubkey: senderPubkey, isNip04: isNip04,
                            responseRelays: responseRelays,
                            responseRelayUrl: responseRelayUrl
                        )
                        return result
                    }
                }

                if !isExistingClient {
                    let perms = ClientPermissions(
                        pubkey: senderPubkey,
                        trustLevel: .medium,
                        kindOverrides: [:],
                        methodPermissions: ClientPermissions.defaultMethodPermissions,
                        name: clientName,
                        url: nil,
                        imageURL: nil,
                        connectedAt: Date().timeIntervalSince1970,
                        lastSeen: Date().timeIntervalSince1970,
                        requestCount: 0
                    )
                    SharedStorage.saveClientPermissions(perms)
                    logger.notice("[LightSigner] New client paired with valid secret")
                } else {
                    logger.notice("[LightSigner] Existing client re-paired with valid secret")
                }
                _ = SharedStorage.rotateBunkerSecret()
            } else if SharedStorage.getClientPermissions(for: senderPubkey) != nil {
                // Already has permissions — allow reconnect without secret
                logger.notice("[LightSigner] Already-paired client reconnecting")
            } else {
                // Wrong or missing secret and no permissions — reject
                logger.notice("[LightSigner] Connect rejected: invalid secret")
                let result = RequestResult(method: method, eventKind: nil, clientPubkey: senderPubkey,
                                           status: "blocked", errorMessage: "Invalid or missing secret")
                logAndTrack(result: result, clientName: clientName)
                try await sendErrorResponse(
                    requestId: requestId, error: "Invalid or missing bunker secret",
                    privateKey: privateKey, senderPubkeyData: senderPubkeyData,
                    senderPubkey: senderPubkey, isNip04: isNip04,
                    responseRelays: responseRelays,
                    responseRelayUrl: responseRelayUrl
                )
                return result
            }
        } else {
            let perms = SharedStorage.getClientPermissions(for: senderPubkey)

            if perms == nil {
                // Unpaired clients may ONLY send `connect` — everything else (including kind:22242
                // NIP-42 relay auth) requires a prior successful pair via bunker secret or
                // nostrconnect handshake. Historical note: we briefly exempted kind:22242 here to
                // avoid a chicken-and-egg during initial auth, but that was a security bug
                // (audit 2026-04-17 finding D.5.1 — attacker-controlled relay URL + challenge
                // could be signed, enabling NIP-42 impersonation on AUTH-gated relays).
                // The ordering race it worked around is now handled by NotificationService +
                // ClaveApp sorting `connect` events to the front of each batch before dispatch.
                logger.notice("[LightSigner] Rejecting unpaired client for method \(method, privacy: .public)")
                let result = RequestResult(method: method, eventKind: eventKind, clientPubkey: senderPubkey,
                                           status: "blocked", errorMessage: "Client not paired")
                logAndTrack(result: result, clientName: clientName)
                try await sendErrorResponse(
                    requestId: requestId, error: "Client not paired — send connect with valid bunker secret first",
                    privateKey: privateKey, senderPubkeyData: senderPubkeyData,
                    senderPubkey: senderPubkey, isNip04: isNip04,
                    responseRelays: responseRelays,
                    responseRelayUrl: responseRelayUrl
                )
                return result
            }

            // Per-client permission enforcement
            if let perms, !skipProtection {
                var allowed = true

                switch method {
                case "sign_event":
                    // Fail closed: if the event kind couldn't be parsed from params, reject.
                    // Don't let a malformed/unparseable sign_event slip through the permission
                    // check (audit finding D.5.2 — previously `allowed` stayed `true` if
                    // extractEventKind returned nil).
                    guard let kind = eventKind else {
                        allowed = false
                        break
                    }
                    allowed = perms.isKindAllowed(kind, protectedKinds: SharedStorage.getProtectedKinds())
                case "nip04_encrypt", "nip04_decrypt", "nip44_encrypt", "nip44_decrypt":
                    allowed = perms.isMethodAllowed(method)
                case "connect", "ping", "get_public_key", "describe", "switch_relays":
                    allowed = true
                default:
                    allowed = true
                }

                if !allowed {
                    logger.notice("[LightSigner] Permission denied for \(method, privacy: .public) — queuing for approval")

                    // Serialize the full request event so the app can process it later
                    var queuedRequestId: String? = nil
                    if let eventData = try? JSONSerialization.data(withJSONObject: requestEvent),
                       let eventJSON = String(data: eventData, encoding: .utf8) {
                        let pending = PendingRequest(
                            id: UUID().uuidString,
                            requestEventJSON: eventJSON,
                            method: method,
                            eventKind: eventKind ?? 0,
                            clientPubkey: senderPubkey,
                            timestamp: Date().timeIntervalSince1970,
                            responseRelayUrl: responseRelayUrl
                        )
                        SharedStorage.queuePendingRequest(pending)
                        queuedRequestId = pending.id
                    }

                    let result = RequestResult(method: method, eventKind: eventKind, clientPubkey: senderPubkey,
                                               status: "pending", errorMessage: "Queued for approval",
                                               pendingRequestId: queuedRequestId)
                    logAndTrack(result: result, clientName: clientName)
                    try await sendErrorResponse(
                        requestId: requestId, error: "Permission denied — open Clave to approve",
                        privateKey: privateKey, senderPubkeyData: senderPubkeyData,
                        senderPubkey: senderPubkey, isNip04: isNip04,
                        responseRelays: responseRelays,
                        responseRelayUrl: responseRelayUrl
                    )
                    return result
                }
            }
        }

        // Process the request
        let (responseResult, responseError) = processRequest(method: method, params: params, privateKey: privateKey)

        var responseDict: [String: Any] = ["id": requestId]
        if let responseResult {
            responseDict["result"] = responseResult
        }
        if let responseError {
            responseDict["error"] = responseError
        }

        guard let responseData = try? JSONSerialization.data(withJSONObject: responseDict),
              let responseJSON = String(data: responseData, encoding: .utf8) else {
            logger.error("[LightSigner] Failed to serialize response")
            let result = RequestResult(method: method, eventKind: eventKind, clientPubkey: senderPubkey,
                                       status: "error", errorMessage: "Serialization failed")
            logAndTrack(result: result, clientName: clientName)
            return result
        }

        // Respond with same encryption the client used
        let encryptedResponse: String
        if isNip04 {
            encryptedResponse = try LightCrypto.nip04Encrypt(
                privateKey: privateKey,
                publicKey: senderPubkeyData,
                plaintext: responseJSON
            )
        } else {
            encryptedResponse = try LightCrypto.nip44Encrypt(
                privateKey: privateKey,
                publicKey: senderPubkeyData,
                plaintext: responseJSON
            )
        }

        let responseEvent = try LightEvent.sign(
            privateKey: privateKey,
            kind: 24133,
            content: encryptedResponse,
            tags: [["p", senderPubkey]]
        )

        let eventJSON = responseEvent.toJSON()
        guard let eventData = eventJSON.data(using: .utf8),
              let eventDict = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any] else {
            logger.error("[LightSigner] Failed to serialize event for publish")
            let result = RequestResult(method: method, eventKind: eventKind, clientPubkey: senderPubkey,
                                       status: "error", errorMessage: "Publish serialization failed")
            logAndTrack(result: result, clientName: clientName)
            return result
        }

        let accepted: Bool
        if let responseRelays = responseRelays, !responseRelays.isEmpty {
            // nostrconnect handshake: publish to all already-connected URI relays.
            // Best-effort — accepted if at least one relay took the event.
            accepted = await publishResponseToRelays(responseRelays, event: eventDict)
        } else {
            // Bunker/NSE path: publish to the relay the request came in on
            // (origin relay from push payload), falling back to the primary
            // relay for handshake paths that don't have an origin yet.
            let relayUrlString = responseRelayUrl ?? SharedConstants.relayURL
            let relay = LightRelay(url: relayUrlString)
            try await relay.connect(timeout: 5.0)
            accepted = (try? await relay.publishEvent(event: eventDict)) ?? false
            relay.disconnect()
        }

        let status: String
        let errorMsg: String?
        if let responseError {
            status = "error"
            errorMsg = responseError
        } else if accepted {
            status = "signed"
            errorMsg = nil
            logger.notice("[LightSigner] Response published successfully")
        } else {
            status = "error"
            errorMsg = "Relay rejected response"
            logger.error("[LightSigner] Relay did not accept response event")
        }

        // Enrich activity log for successful sign_event with the resulting
        // event id and a tag-derived one-liner. Side-effect: kind:3 also
        // updates the persisted contact-set snapshot used for diffing.
        var signedEventId: String? = nil
        var signedSummary: String? = nil
        if status == "signed", method == "sign_event", let json = responseResult {
            (signedEventId, signedSummary) = extractSignedEventEnrichment(signedEventJSON: json)
        }

        let result = RequestResult(method: method, eventKind: eventKind, clientPubkey: senderPubkey,
                                   status: status, errorMessage: errorMsg,
                                   signedEventId: signedEventId, signedSummary: signedSummary)
        logAndTrack(result: result, clientName: clientName)
        return result
    }

    /// Parse the signed-event JSON returned by `processRequest("sign_event", …)`
    /// to extract the event id and build the activity summary. For kind:3, also
    /// reads + updates the stored contact-set snapshot so the next sign can diff.
    /// Failures are best-effort — returns (nil, nil) and lets logging proceed.
    private static func extractSignedEventEnrichment(signedEventJSON: String) -> (String?, String?) {
        guard let data = signedEventJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let id = dict["id"] as? String
        let kind = dict["kind"] as? Int
        let rawTags = dict["tags"] as? [[Any]] ?? []
        let tags: [[String]] = rawTags.map { row in row.compactMap { $0 as? String } }

        guard let kind else { return (id, nil) }

        // Kind:3 uses the prior snapshot to compute follow add/remove diffs.
        // Update the snapshot post-summary so the diff reflects what changed
        // *with this sign*, not what would have changed against a stale set.
        let previous: Set<String>?
        if kind == 3 {
            previous = SharedStorage.getLastContactSet()
        } else {
            previous = nil
        }

        let summary = ActivitySummary.signedSummary(kind: kind, tags: tags, previousContactSet: previous)

        if kind == 3 {
            let newSet = Set(tags.compactMap { tag -> String? in
                guard tag.first == "p", tag.count >= 2 else { return nil }
                return tag[1]
            })
            // Only persist when within the diff cap; over-cap kind:3 doesn't
            // benefit from a snapshot (we fall back to "Updated contact list (N follows)").
            if newSet.count <= ActivitySummary.kind3DiffCap {
                SharedStorage.saveLastContactSet(newSet)
            }
        }

        return (id, summary)
    }

    // MARK: - Request Processing

    static func processRequest(method: String, params: [String], privateKey: Data) -> (String?, String?) {
        switch method {
        case "ping":
            return ("pong", nil)

        case "get_public_key":
            do {
                let pubkey = try LightEvent.pubkeyHex(from: privateKey)
                return (pubkey, nil)
            } catch {
                return (nil, "Failed to derive pubkey: \(error.localizedDescription)")
            }

        case "sign_event":
            guard let eventJson = params.first else {
                return (nil, "Missing event parameter")
            }
            do {
                let signed = try LightEvent.signUnsignedEvent(privateKey: privateKey, unsignedJSON: eventJson)
                return (signed.toJSON(), nil)
            } catch {
                return (nil, "Sign failed: \(error.localizedDescription)")
            }

        case "connect":
            if params.count >= 2, !params[1].isEmpty {
                return (params[1], nil)
            }
            return ("ack", nil)

        case "nip04_encrypt":
            guard params.count >= 2 else { return (nil, "Missing params") }
            guard let pubkeyData = Data(hexString: params[0]) else { return (nil, "Invalid pubkey") }
            do {
                let ciphertext = try LightCrypto.nip04Encrypt(privateKey: privateKey, publicKey: pubkeyData, plaintext: params[1])
                return (ciphertext, nil)
            } catch {
                return (nil, "nip04_encrypt failed: \(error.localizedDescription)")
            }

        case "nip04_decrypt":
            guard params.count >= 2 else { return (nil, "Missing params") }
            guard let pubkeyData = Data(hexString: params[0]) else { return (nil, "Invalid pubkey") }
            do {
                let plaintext = try LightCrypto.nip04Decrypt(privateKey: privateKey, publicKey: pubkeyData, payload: params[1])
                return (plaintext, nil)
            } catch {
                return (nil, "nip04_decrypt failed: \(error.localizedDescription)")
            }

        case "nip44_encrypt":
            guard params.count >= 2 else { return (nil, "Missing params") }
            guard let pubkeyData = Data(hexString: params[0]) else { return (nil, "Invalid pubkey") }
            do {
                let ciphertext = try LightCrypto.nip44Encrypt(privateKey: privateKey, publicKey: pubkeyData, plaintext: params[1])
                return (ciphertext, nil)
            } catch {
                return (nil, "nip44_encrypt failed: \(error.localizedDescription)")
            }

        case "nip44_decrypt":
            guard params.count >= 2 else { return (nil, "Missing params") }
            guard let pubkeyData = Data(hexString: params[0]) else { return (nil, "Invalid pubkey") }
            do {
                let plaintext = try LightCrypto.nip44Decrypt(privateKey: privateKey, publicKey: pubkeyData, payload: params[1])
                return (plaintext, nil)
            } catch {
                return (nil, "nip44_decrypt failed: \(error.localizedDescription)")
            }

        case "switch_relays":
            // Return JSON null per NIP-46 ("null if there is nothing to be
            // changed"). Matches Amber's responder-only pattern and NDK's
            // default switchRelays handler. Returning a concrete relay array
            // here triggered welshman pool migration in Coracle and stalled
            // the pairing UI. Validated on TestFlight builds 16+17.
            return ("null", nil)

        case "describe":
            return ("[\"connect\",\"sign_event\",\"get_public_key\",\"ping\",\"nip04_encrypt\",\"nip04_decrypt\",\"nip44_encrypt\",\"nip44_decrypt\",\"switch_relays\",\"describe\"]", nil)

        default:
            return (nil, "Unsupported method: \(method)")
        }
    }

    // MARK: - Helpers

    private static func extractEventKind(method: String, params: [String]) -> Int? {
        guard method == "sign_event", let eventJson = params.first,
              let data = eventJson.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = dict["kind"] as? Int else {
            return nil
        }
        return kind
    }

    private static func extractConnectName(params: [String]) -> String? {
        // connect params: [pubkey, secret?, perms?] — name might be in the URI or absent
        // The client name comes from the nostrconnect URI which isn't in params directly
        nil
    }

    private static func logAndTrack(result: RequestResult, clientName: String? = nil) {
        let entry = ActivityEntry(
            id: UUID().uuidString,
            method: result.method,
            eventKind: result.eventKind,
            clientPubkey: result.clientPubkey,
            timestamp: Date().timeIntervalSince1970,
            status: result.status,
            errorMessage: result.errorMessage,
            signedEventId: result.signedEventId,
            signedSummary: result.signedSummary
        )
        SharedStorage.logActivity(entry)
        if result.clientPubkey != "unknown" && result.status != "blocked"
            && SharedStorage.getClientPermissions(for: result.clientPubkey) != nil {
            SharedStorage.touchClient(pubkey: result.clientPubkey)
        }
    }

    /// Publish an event to multiple already-connected relays in parallel.
    /// Returns true if at least one relay accepted the event.
    private static func publishResponseToRelays(_ relays: [LightRelay], event: [String: Any]) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            for relay in relays {
                group.addTask {
                    (try? await relay.publishEvent(event: event)) ?? false
                }
            }
            var anyAccepted = false
            for await ok in group {
                if ok { anyAccepted = true }
            }
            return anyAccepted
        }
    }

    private static func sendErrorResponse(
        requestId: String, error: String,
        privateKey: Data, senderPubkeyData: Data,
        senderPubkey: String, isNip04: Bool,
        responseRelays: [LightRelay]? = nil,
        responseRelayUrl: String? = nil
    ) async throws {
        let responseDict: [String: Any] = ["id": requestId, "error": error]
        guard let responseData = try? JSONSerialization.data(withJSONObject: responseDict),
              let responseJSON = String(data: responseData, encoding: .utf8) else { return }

        let encrypted: String
        if isNip04 {
            encrypted = try LightCrypto.nip04Encrypt(privateKey: privateKey, publicKey: senderPubkeyData, plaintext: responseJSON)
        } else {
            encrypted = try LightCrypto.nip44Encrypt(privateKey: privateKey, publicKey: senderPubkeyData, plaintext: responseJSON)
        }

        let event = try LightEvent.sign(privateKey: privateKey, kind: 24133, content: encrypted, tags: [["p", senderPubkey]])
        guard let eventData = event.toJSON().data(using: .utf8),
              let eventDict = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any] else {
            return
        }

        if let responseRelays = responseRelays, !responseRelays.isEmpty {
            _ = await publishResponseToRelays(responseRelays, event: eventDict)
        } else {
            let relayUrlString = responseRelayUrl ?? SharedConstants.relayURL
            let relay = LightRelay(url: relayUrlString)
            try await relay.connect(timeout: 5.0)
            _ = try? await relay.publishEvent(event: eventDict)
            relay.disconnect()
        }
    }

    /// Decrypt just enough of a kind:24133 event to determine its NIP-46 method.
    /// Returns nil if the event is malformed, not addressed to us, or the JSON-RPC payload is invalid.
    /// Used by the NSE + foreground signing loops to sort events so that `connect` requests are
    /// processed before other methods within a single batch, eliminating the ordering race that
    /// previously required the unpaired-22242 bypass.
    static func peekMethod(privateKey: Data, event: [String: Any]) -> String? {
        guard let senderPubkey = event["pubkey"] as? String,
              let encryptedContent = event["content"] as? String,
              let senderPubkeyData = Data(hexString: senderPubkey) else {
            return nil
        }
        guard let plaintext = try? LightCrypto.decrypt(
            privateKey: privateKey,
            publicKey: senderPubkeyData,
            payload: encryptedContent
        ) else {
            return nil
        }
        guard let data = plaintext.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else {
            return nil
        }
        return method
    }
}
