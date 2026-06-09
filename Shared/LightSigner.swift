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
        /// First `e` tag for wrapper-around-reference kinds (6, 7, 9734,
        /// 9735). Forwarded into ActivityEntry to redirect the njump
        /// button to the more-meaningful target.
        var signedReferencedEventId: String? = nil
        /// Full JSON of the signed event, captured at sign time for the
        /// "View raw event" disclosure on `ActivityDetailView`. Set only
        /// for successful sign_event results; nil otherwise.
        var signedEventJSON: String? = nil
        /// For `nip44v3_*` results: the caller-supplied kind from the RPC
        /// params, captured so `logAndTrack` can stamp the resulting
        /// ActivityEntry with the same context the live prompt rendered.
        /// nil for non-v3 methods.
        var v3Kind: UInt32? = nil
        /// For `nip44v3_*` results: caller-supplied scope from the RPC
        /// params (raw UTF-8 string).
        var v3Scope: String? = nil
    }

    static func handleRequest(
        privateKey: Data,
        requestEvent: [String: Any],
        skipProtection: Bool = false,
        skipDedupe: Bool = false,
        responseRelays: [LightRelay]? = nil,
        responseRelayUrl: String? = nil
    ) async throws -> RequestResult {
        guard let senderPubkey = requestEvent["pubkey"] as? String,
              let encryptedContent = requestEvent["content"] as? String else {
            logger.error("[LightSigner] Invalid event: missing pubkey or content")
            return RequestResult(method: "unknown", eventKind: nil, clientPubkey: "unknown",
                                 status: "error", errorMessage: "Invalid event")
        }

        // Derive the signer's pubkey from the supplied private key once per
        // request. Used by Task 4 multi-account scoping for bunker secrets,
        // touchClient, and kind:3 lastContactSet. If derivation fails (would
        // indicate a fundamentally invalid privateKey, which shouldn't pass
        // earlier guards), per-signer storage ops fall through to empty-key
        // bucket — non-fatal but bounded.
        let signerPubkey = (try? LightEvent.pubkeyHex(from: privateKey)) ?? ""

        // Signature verification (path-wide) — PHASE 2: ENFORCED. Recompute the
        // event id + BIP-340 Schnorr verify; failure means a forged / tampered /
        // replayed-with-freshened-envelope event. Drop it SILENTLY (status
        // "blocked" + nil errorMessage + no response → the NSE blanks it, no
        // "Signing Failed" banner, so a forged-event flood can't spam the user's
        // Notification Center). Runs before dedup so a forged/freshened id can't
        // pollute the dedup ring or be trusted by the freshness window.
        // Validated pre-enforcement against the 161-event real-relay corpus
        // (LightEventCorpusTests) + an independent go-nostr vector.
        if !LightEvent.verify(event: requestEvent) {
            logger.error("[LightSigner] SIGCHECK REJECT eid=\((requestEvent["id"] as? String)?.prefix(8) ?? "?", privacy: .public) sender=\(senderPubkey.prefix(8), privacy: .public)")
            return RequestResult(method: "unknown", eventKind: nil, clientPubkey: senderPubkey,
                                 status: "blocked", errorMessage: nil)
        }

        // Per-event-id dedupe (audit D.1.1). Both NSE and the foreground
        // relay subscription (Layer 1) call into this function; whichever
        // marks first wins, others skip. Cross-process semantics are lossy
        // by design — see SharedStorage.markEventProcessed.
        //
        // `skipDedupe` is set by the pending-approval replay path
        // (`AppState.approvePendingRequest`): NSE marked the event id as
        // processed when it queued the request, so a fast approve (<60s
        // window) would otherwise short-circuit here without producing the
        // "signed" activity entry. Pending approvals are not new arrivals
        // racing other processes — they are a deliberate replay of a
        // known-queued event, so dedupe doesn't apply.
        let eventId = (requestEvent["id"] as? String) ?? ""
        let createdAt = (requestEvent["created_at"] as? Double)
            ?? Double(requestEvent["created_at"] as? Int ?? 0)
        let nowFallback = Date().timeIntervalSince1970
        if !skipDedupe,
           !eventId.isEmpty,
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
            logAndTrack(result: result, signerPubkey: signerPubkey)
            return result
        }

        guard let data = decrypted.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requestId = json["id"] as? String,
              let method = json["method"] as? String else {
            logger.error("[LightSigner] Failed to parse JSON-RPC")
            let result = RequestResult(method: "unknown", eventKind: nil, clientPubkey: senderPubkey,
                                       status: "error", errorMessage: "Invalid JSON-RPC")
            logAndTrack(result: result, signerPubkey: signerPubkey)
            return result
        }

        let params: [String]
        if let strs = json["params"] as? [String] {
            params = strs
        } else {
            // Some clients send mixed-type params (e.g. an object for sign_event
            // instead of the spec-required JSON-stringified string). Without
            // this log, the request silently degrades to "missing params"
            // downstream and the wire trace can't tell shape-mismatch from
            // genuinely-missing-params. Helps client-side debugging.
            if let raw = json["params"] {
                logger.warning("[LightSigner] params not [String]: type=\(String(describing: type(of: raw)), privacy: .public) method=\(method, privacy: .public) id=\(requestId.prefix(8), privacy: .public)")
            }
            params = []
        }
        logger.notice("[LightSigner] Method: \(method, privacy: .public) id=\(requestId.prefix(8), privacy: .public)")

        // Extract event kind for sign_event
        let eventKind = extractEventKind(method: method, params: params)

        // Extract v3 context (kind + scope) once for the lifetime of this
        // request. v3 RPCs carry kind as a stringified u32 in params[1] and
        // scope as raw UTF-8 in params[2]. Each RequestResult constructed
        // below for v3 methods picks these up so the resulting ActivityEntry
        // renders the same kind label + scope row + tier banner the live
        // prompt showed. Nil for non-v3 methods.
        let isV3Method = method == "nip44v3_encrypt" || method == "nip44v3_decrypt"
        let v3Kind: UInt32? = isV3Method && params.count > 1 ? UInt32(params[1]) : nil
        let v3Scope: String? = isV3Method && params.count > 2 ? params[2] : nil

        // Extract client name for connect
        let clientName = (method == "connect" && !params.isEmpty) ? extractConnectName(params: params) : nil

        // --- Per-client permission checks ---
        if method == "connect" {
            // connect params: [remote-signer-pubkey, optional-secret, optional-perms]
            // Audit-2: warn (don't reject) when params[0] doesn't match this
            // signer's pubkey. Routing already worked via the kind:24133 #p
            // tag so a mismatch is informational — but it's a useful diagnostic
            // for clients that pick the wrong target in multi-account flows.
            if let target = params.first, !target.isEmpty, target != signerPubkey {
                logger.warning("[LightSigner] connect target mismatch: params[0]=\(target.prefix(8), privacy: .public) signer=\(signerPubkey.prefix(8), privacy: .public)")
            }
            let providedSecret = params.count >= 2 ? params[1] : ""
            let expectedSecret = SharedStorage.getBunkerSecret(for: signerPubkey)

            if !providedSecret.isEmpty && providedSecret == expectedSecret {
                // Valid secret — check cap before creating new permissions.
                // Bug E fix: scope existence check to (current signer, sender)
                // so a client paired with one account doesn't skip permissions
                // creation when bunker-connecting to a different account.
                // Previously the legacy `getClientPermissions(for:)` scanned
                // all signers, so isExistingClient=true for any cross-paired
                // client → row never written for the new (signer, client)
                // pair → HomeView's signer-scoped list missed the connection
                // and per-connection activity lookups returned no entries.
                let isExistingClient = SharedStorage.getClientPermissions(signer: signerPubkey, client: senderPubkey) != nil
                if !isExistingClient {
                    // Per-account scoping: count only this signer's clients.
                    // Was using the unscoped getConnectedClients() which sums
                    // every account's clients on the device — would falsely
                    // reject a bunker-connect to a fresh account when other
                    // accounts already had pairings. ApprovalSheet's cap check
                    // (nostrconnect URI flow) was already per-signer; this
                    // brings the bunker URI flow in line.
                    let currentCount = SharedStorage.getConnectedClients(for: signerPubkey).count
                    if currentCount >= Account.maxClientsPerAccount {
                        logger.notice("[LightSigner] Bunker connect rejected: pairing cap reached (\(Account.maxClientsPerAccount))")
                        let result = RequestResult(
                            method: method, eventKind: nil, clientPubkey: senderPubkey,
                            status: "blocked", errorMessage: "Pairing limit reached (\(Account.maxClientsPerAccount))"
                        )
                        logAndTrack(result: result, signerPubkey: signerPubkey, clientName: clientName)
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
                        requestCount: 0,
                        signerPubkeyHex: signerPubkey
                    )
                    SharedStorage.saveClientPermissions(perms)
                    // Sprint 5a fix: also create the ConnectedClient row at
                    // pair-time so the next bunker connect's cap-check at
                    // line 175-176 sees this client. Pre-fix, the row was
                    // created lazily by SharedStorage.updateClient on the
                    // first signing request, so multiple bunker pairs could
                    // land between connect and first sign without any of
                    // them counting toward the 5-cap (field-tested 7-pair
                    // bypass on build 63).
                    //
                    // Mirrors AppState.bunkerURI(for:) — bunker URI is
                    // currently single-relay (SharedConstants.relayURL).
                    // When multi-relay bunker URIs land (BACKLOG: "Multi-
                    // relay bunker URI"), update this to match the URI
                    // generator's relay set.
                    SharedStorage.setClientRelayUrls(
                        pubkey: senderPubkey,
                        relayUrls: [SharedConstants.relayURL],
                        signer: signerPubkey
                    )
                    logger.notice("[LightSigner] New client paired with valid secret (row created, relay=\(SharedConstants.relayURL, privacy: .public))")
                } else {
                    logger.notice("[LightSigner] Existing client re-paired with valid secret")
                }
                _ = SharedStorage.rotateBunkerSecret(for: signerPubkey)
            } else if SharedStorage.getClientPermissions(signer: signerPubkey, client: senderPubkey) != nil {
                // Already paired with THIS (signer, client) — allow reconnect
                // without secret. Bug E fix: scope to current signer so a
                // client paired with account A can't reconnect to account B
                // without re-providing B's bunker secret.
                logger.notice("[LightSigner] Already-paired client reconnecting")
            } else {
                // Wrong or missing secret and no permissions — reject
                logger.notice("[LightSigner] Connect rejected: invalid secret")
                let result = RequestResult(method: method, eventKind: nil, clientPubkey: senderPubkey,
                                           status: "blocked", errorMessage: "Invalid or missing secret",
                                           v3Kind: v3Kind, v3Scope: v3Scope)
                logAndTrack(result: result, signerPubkey: signerPubkey, clientName: clientName)
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
            // Bug E fix: scope to (current signer, sender). The legacy
            // `getClientPermissions(for: senderPubkey)` returned a row for
            // any signer that had paired this client — letting a sign_event
            // RPC with `p`-tag pointing at signer B be signed by B's nsec
            // even though only signer A had approved this client. Real
            // authorization leak. Now the gate requires explicit (signer,
            // client) consent.
            let perms = SharedStorage.getClientPermissions(signer: signerPubkey, client: senderPubkey)

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
                                           status: "blocked", errorMessage: "Client not paired",
                                           v3Kind: v3Kind, v3Scope: v3Scope)
                logAndTrack(result: result, signerPubkey: signerPubkey, clientName: clientName)
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
                case "nip44v3_encrypt", "nip44v3_decrypt":
                    // v3 methods carry caller-supplied (kind, scope) in params[1] and
                    // params[2]. Look up the granular (method, kind, scope?) grant
                    // stored in v3KindScopePermissions by the approval UI. Both the
                    // exact (kind, scope) match and the wildcard (kind, nil)
                    // "always allow this kind" match return true; otherwise the
                    // request goes through the approval queue.
                    //
                    // Per spec extensions/nip46.md: params shape is
                    // (pubkey_hex, kind_u32_string, scope_utf8, plaintext_b64-or-ct).
                    if params.count >= 3, let kindVal = UInt32(params[1]) {
                        allowed = perms.isV3CallAllowed(method: method, kind: kindVal, scope: params[2])
                    } else {
                        // Malformed v3 request — surface to user, don't auto-approve.
                        allowed = false
                    }
                case "connect", "ping", "get_public_key", "describe", "switch_relays":
                    allowed = true
                default:
                    allowed = true
                }

                if !allowed {
                    logger.notice("[LightSigner] Permission denied for \(method, privacy: .public) — queuing for approval")

                    // For nip44v3_* requests, capture kind+scope from the RPC
                    // params so the approval UI can render the context without
                    // re-parsing the inner JSON-RPC. params[1] is the kind as
                    // a stringified u32, params[2] is the scope as raw UTF-8.
                    let v3Kind: UInt32?
                    let v3Scope: String?
                    if method == "nip44v3_encrypt" || method == "nip44v3_decrypt" {
                        v3Kind = params.count > 1 ? UInt32(params[1]) : nil
                        v3Scope = params.count > 2 ? params[2] : nil
                    } else {
                        v3Kind = nil
                        v3Scope = nil
                    }

                    // Serialize the full request event so the app can process it later
                    var queuedRequestId: String? = nil
                    if let eventData = try? JSONSerialization.data(withJSONObject: requestEvent),
                       let eventJSON = String(data: eventData, encoding: .utf8) {
                        let pending = PendingRequest(
                            id: UUID().uuidString,
                            requestEventJSON: eventJSON,
                            method: method,
                            // Pass nil through when extractEventKind couldn't find a kind
                            // (only sign_event populates eventKind today). A `?? 0` here
                            // would store Optional(0) which the detail view treats as a
                            // valid kind and renders as "Kind 0 — Profile Metadata"
                            // alongside the v3Kind row for v3 requests.
                            eventKind: eventKind,
                            clientPubkey: senderPubkey,
                            timestamp: Date().timeIntervalSince1970,
                            responseRelayUrl: responseRelayUrl,
                            signerPubkeyHex: signerPubkey,
                            v3Kind: v3Kind,
                            v3Scope: v3Scope
                        )
                        SharedStorage.queuePendingRequest(pending)
                        queuedRequestId = pending.id
                    }

                    let result = RequestResult(method: method, eventKind: eventKind, clientPubkey: senderPubkey,
                                               status: "pending", errorMessage: "Queued for approval",
                                               pendingRequestId: queuedRequestId,
                                               v3Kind: v3Kind, v3Scope: v3Scope)
                    logAndTrack(result: result, signerPubkey: signerPubkey, clientName: clientName)
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

        // NIP-46 response shape is {id, result, error}. The `result` field
        // MUST be present even on error responses (empty string per JSON-RPC
        // convention) — strict parsers (e.g. nostr-tools' BunkerSigner under
        // certain code paths) ignore responses missing `result` and time out
        // instead of surfacing the error. Closes audit-5 from the 2026-04-17
        // pre-external-TestFlight audit; symptom was clave.casa staying on a
        // stale edit page for 45s after a server-side unpair instead of
        // recovering immediately on the explicit "Invalid or missing bunker
        // secret" error this view-of-iOS already sends.
        var responseDict: [String: Any] = ["id": requestId, "result": responseResult ?? ""]
        if let responseError {
            responseDict["error"] = responseError
        }

        guard let responseData = try? JSONSerialization.data(withJSONObject: responseDict),
              let responseJSON = String(data: responseData, encoding: .utf8) else {
            logger.error("[LightSigner] Failed to serialize response")
            let result = RequestResult(method: method, eventKind: eventKind, clientPubkey: senderPubkey,
                                       status: "error", errorMessage: "Serialization failed",
                                       v3Kind: v3Kind, v3Scope: v3Scope)
            logAndTrack(result: result, signerPubkey: signerPubkey, clientName: clientName)
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
                                       status: "error", errorMessage: "Publish serialization failed",
                                       v3Kind: v3Kind, v3Scope: v3Scope)
            logAndTrack(result: result, signerPubkey: signerPubkey, clientName: clientName)
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
        // For successful sign_event, also retain the signed event JSON
        // for the activity detail's "View raw event" disclosure.
        var signedEventId: String? = nil
        var signedSummary: String? = nil
        var signedReferencedEventId: String? = nil
        var signedEventJSON: String? = nil
        if status == "signed", method == "sign_event", let json = responseResult {
            let enrichment = extractSignedEventEnrichment(signedEventJSON: json, signerPubkey: signerPubkey)
            signedEventId = enrichment.eventId
            signedSummary = enrichment.summary
            signedReferencedEventId = enrichment.referencedEventId
            signedEventJSON = json
        }

        let result = RequestResult(method: method, eventKind: eventKind, clientPubkey: senderPubkey,
                                   status: status, errorMessage: errorMsg,
                                   signedEventId: signedEventId, signedSummary: signedSummary,
                                   signedReferencedEventId: signedReferencedEventId,
                                   signedEventJSON: signedEventJSON,
                                   v3Kind: v3Kind, v3Scope: v3Scope)
        logAndTrack(result: result, signerPubkey: signerPubkey, clientName: clientName)
        return result
    }

    /// Kinds where the signed event is a wrapper around a referenced event
    /// (first `e` tag). For these, the activity detail's njump button should
    /// link to the referenced event, not the wrapper itself — a "❤" reaction
    /// or repost is meaningless on njump in isolation.
    static let wrapperKinds: Set<Int> = [6, 7, 9734, 9735]

    /// Parse the signed-event JSON returned by `processRequest("sign_event", …)`
    /// to extract the event id and build the activity summary. For kind:3, also
    /// reads + updates the stored contact-set snapshot so the next sign can diff.
    /// Failures are best-effort — returns (nil, nil, nil) and lets logging proceed.
    /// Internal (not private) so unit tests can verify enrichment shape without
    /// constructing a full encrypted NIP-46 envelope.
    static func extractSignedEventEnrichment(signedEventJSON: String, signerPubkey: String = "") -> (eventId: String?, summary: String?, referencedEventId: String?) {
        // `signerPubkey` is required for correct kind:3 lastContactSet
        // scoping (Task 4 of multi-account sprint). Defaulted to "" for
        // source-compat with existing tests; production callers in
        // `handleRequest` always pass the real signer pubkey derived from
        // the request's privateKey. See ~/hq/clave/security-audits/
        // 2026-04-30-multi-account-pre-implementation.md for the
        // cross-account corruption hazard this prevents.
        guard let data = signedEventJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil, nil)
        }
        let id = dict["id"] as? String
        let kind = dict["kind"] as? Int
        let rawTags = dict["tags"] as? [[Any]] ?? []
        let tags: [[String]] = rawTags.map { row in row.compactMap { $0 as? String } }

        guard let kind else { return (id, nil, nil) }

        // Kind:3 uses the prior snapshot to compute follow add/remove diffs.
        // Update the snapshot post-summary so the diff reflects what changed
        // *with this sign*, not what would have changed against a stale set.
        let previous: Set<String>?
        if kind == 3 {
            previous = SharedStorage.getLastContactSet(for: signerPubkey)
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
                SharedStorage.saveLastContactSet(newSet, for: signerPubkey)
            }
        }

        // Pull the first `e` tag for wrapper kinds so the njump button can
        // redirect to the referenced event (e.g., the note that was reacted
        // to, not the reaction itself). Validated as 64-char hex to avoid
        // crashing the encoder on malformed tags.
        var referencedEventId: String? = nil
        if wrapperKinds.contains(kind) {
            for tag in tags where tag.first == "e" && tag.count >= 2 {
                let candidate = tag[1]
                if candidate.count == 64,
                   candidate.allSatisfy({ $0.isHexDigit }) {
                    referencedEventId = candidate
                    break
                }
            }
        }

        return (id, summary, referencedEventId)
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

        // MARK: NIP-44 v3 (extensions/nip46.md)
        //
        // 4-param signature: (pubkey_hex, kind_u32_string, scope_utf8, plaintext_b64 / ciphertext).
        // kind+scope are caller-supplied AND bound into the MAC by NIP44v3.encrypt/decrypt,
        // so a client lying about either causes MAC verify to fail. The decrypt path
        // does NOT validate padding length (spec commit c6daedd, Amber PR #456 gotcha).

        case "nip44v3_encrypt":
            guard params.count >= 4 else { return (nil, "Missing params") }
            guard let pubkeyData = Data(hexString: params[0]) else { return (nil, "Invalid pubkey") }
            guard let kindVal = UInt32(params[1]) else { return (nil, "Invalid kind") }
            let scopeBytes = Data(params[2].utf8)
            guard let plaintextData = Data(base64Encoded: params[3]) else { return (nil, "Invalid plaintext_b64") }
            do {
                let context = try NIP44v3.Context(kind: kindVal, scope: scopeBytes)
                let ciphertext = try NIP44v3.encrypt(seckey: privateKey, pubkey: pubkeyData, context: context, plaintext: plaintextData)
                return (ciphertext, nil)
            } catch {
                return (nil, "nip44v3_encrypt failed: \(error.localizedDescription)")
            }

        case "nip44v3_decrypt":
            guard params.count >= 4 else { return (nil, "Missing params") }
            guard let pubkeyData = Data(hexString: params[0]) else { return (nil, "Invalid pubkey") }
            guard let kindVal = UInt32(params[1]) else { return (nil, "Invalid kind") }
            let scopeBytes = Data(params[2].utf8)
            do {
                let context = try NIP44v3.Context(kind: kindVal, scope: scopeBytes)
                let plaintext = try NIP44v3.decrypt(seckey: privateKey, pubkey: pubkeyData, context: context, ciphertext: params[3])
                return (plaintext.base64EncodedString(), nil)
            } catch {
                return (nil, "nip44v3_decrypt failed: \(error.localizedDescription)")
            }

        case "switch_relays":
            // Return JSON null per NIP-46 ("null if there is nothing to be
            // changed"). Matches Amber's responder-only pattern and NDK's
            // default switchRelays handler. Returning a concrete relay array
            // here triggered welshman pool migration in Coracle and stalled
            // the pairing UI. Validated on TestFlight builds 16+17.
            return ("null", nil)

        case "describe":
            return ("[\"connect\",\"sign_event\",\"get_public_key\",\"ping\",\"nip04_encrypt\",\"nip04_decrypt\",\"nip44_encrypt\",\"nip44_decrypt\",\"nip44v3_encrypt\",\"nip44v3_decrypt\",\"switch_relays\",\"describe\"]", nil)

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

    /// `signerPubkey` is threaded from `handleRequest` so the activity entry
    /// is stamped with the right signer (Task 3 added the field; Task 4
    /// connects callers) and `touchClient` updates the correct
    /// (signer, client) row in multi-account scenarios.
    private static func logAndTrack(result: RequestResult, signerPubkey: String, clientName: String? = nil) {
        let entry = ActivityEntry(
            id: UUID().uuidString,
            method: result.method,
            eventKind: result.eventKind,
            clientPubkey: result.clientPubkey,
            timestamp: Date().timeIntervalSince1970,
            status: result.status,
            errorMessage: result.errorMessage,
            signedEventId: result.signedEventId,
            signedSummary: result.signedSummary,
            signedReferencedEventId: result.signedReferencedEventId,
            signedEventJSON: result.signedEventJSON,
            signerPubkeyHex: signerPubkey,
            v3Kind: result.v3Kind,
            v3Scope: result.v3Scope
        )
        SharedStorage.logActivity(entry)
        if result.clientPubkey != "unknown" && result.status != "blocked"
            && SharedStorage.getClientPermissions(signer: signerPubkey, client: result.clientPubkey) != nil {
            SharedStorage.touchClient(pubkey: result.clientPubkey, signer: signerPubkey)
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
        // NIP-46 response shape requires `result` field even on errors —
        // see audit-5 + the matching note in handleRequest's response path.
        let responseDict: [String: Any] = ["id": requestId, "result": "", "error": error]
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

    /// Build the `result` field for a NIP-46 `connect` ack.
    ///
    /// Single-account (`isMultiAccount: false`): bare echoed-secret string,
    /// matches today's behavior. Backwards-compatible with all existing
    /// clients including ones that string-compare `result == secret`.
    ///
    /// Multi-account (`isMultiAccount: true`): JSON object
    /// `{echoed_secret, name?, picture?, total}`. Lets multi-aware clients
    /// (Spectr) render account labels without a follow-up kind:0 fetch and
    /// auto-finalize their listening window on `count == total`.
    ///
    /// `total` MUST equal the picker's selected-count exactly per spec.
    /// Pass the same value on every iteration of the N-up handshake loop
    /// (each ack in the batch carries the same `total`).
    static func connectAckResult(
        isMultiAccount: Bool,
        echoedSecret: String,
        accountName: String?,
        accountPicture: String?,
        total: Int
    ) -> String {
        guard isMultiAccount else {
            return echoedSecret
        }
        // Build heterogeneous JSON object: String fields + Int `total`.
        var fields: [String: Any] = [
            "echoed_secret": echoedSecret,
            "total": total
        ]
        if let name = accountName, !name.isEmpty {
            fields["name"] = name
        }
        if let picture = accountPicture, !picture.isEmpty {
            fields["picture"] = picture
        }
        // Sorted keys → deterministic output (helps test assertions + log
        // diffing).
        guard let data = try? JSONSerialization.data(
                withJSONObject: fields,
                options: [.sortedKeys]
              ),
              let str = String(data: data, encoding: .utf8) else {
            // Fallback: if JSON serialization fails (shouldn't happen for
            // plain String + Int fields), degrade to bare secret rather
            // than breaking the handshake.
            return echoedSecret
        }
        return str
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
