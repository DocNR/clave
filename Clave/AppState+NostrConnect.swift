import Foundation

/// NostrConnect (NIP-46) deeplink routing + handshake — extracted from
/// AppState per the AppState god-object refactor (Stage 3a).
///
/// Lives in an extension because the methods read/write @Observable state
/// on AppState (`pendingNostrconnectURI`, `pendingDeeplinkAccountChoice`,
/// `deeplinkBoundAccount`) and call other AppState methods
/// (`pairClientWithProxy` — moves out in Stage 3c). Stored properties
/// remain in the main AppState class declaration (Swift forbids stored
/// properties in extensions).
extension AppState {

    /// Routes an incoming URL deeplink. Called from ClaveApp.onOpenURL via
    /// a NotificationCenter post. Mutates pendingNostrconnectURI or
    /// pendingDeeplinkAccountChoice based on account count. clave:// and
    /// malformed URIs are silently ignored.
    @MainActor
    func handleDeeplink(url: URL) {
        let outcome = DeeplinkRouter.route(url: url, accountCount: accounts.count)
        switch outcome {
        case .approve(let parsed):
            pendingNostrconnectURI = parsed
        case .pickAccount(let parsed):
            pendingDeeplinkAccountChoice = parsed
        case .ignore:
            break
        }
    }

    /// Perform the nostrconnect:// handshake for each signer in `signerPubkeys`.
    /// In Phase 1 this is always 1-element. Phase 2 enables N > 1 for the
    /// multi-account flow — each iteration runs the same handshake with a
    /// different signer's nsec.
    ///
    /// Why multi-relay per iteration: the client (per NIP-46) subscribes on
    /// every relay in its URI; if we publish to only one and that relay drops
    /// the ephemeral kind:24133, the client never sees our response. Publishing
    /// to all is best-effort — we don't fail if some relays reject or are
    /// unreachable, we just need at least one.
    @discardableResult
    func handleNostrConnect(
        parsedURI: NostrConnectParser.ParsedURI,
        signerPubkeys: [String],
        permissions: ClientPermissions
    ) async throws -> HandshakeResult {
        guard !signerPubkeys.isEmpty else {
            throw ClaveError.noSignerKey
        }

        // The picker's selected-count is the authoritative `total` per the
        // multi-account spec. Computed once at the top of the loop so every
        // ack in the batch carries the same value (clients use it to know
        // when they've received all expected acks).
        let total = signerPubkeys.count

        var succeeded: [String] = []
        var failed: [HandshakeResult.FailedSigner] = []

        for signerPubkey in signerPubkeys {
            do {
                try await runSingleConnect(
                    parsedURI: parsedURI,
                    signerPubkey: signerPubkey,
                    permissions: permissions,
                    total: total
                )
                succeeded.append(signerPubkey)
            } catch {
                failed.append(HandshakeResult.FailedSigner(
                    signerPubkey: signerPubkey,
                    errorMessage: error.localizedDescription
                ))
            }
        }

        return HandshakeResult(succeeded: succeeded, failed: failed)
    }

    /// One signer's handshake — body is the pre-refactor handleNostrConnect
    /// with `boundAccountPubkey` replaced by the explicit `signerPubkey`
    /// argument. Phase 2 calls this inside a loop; Phase 1 calls it once.
    private func runSingleConnect(
        parsedURI: NostrConnectParser.ParsedURI,
        signerPubkey resolvedSignerPubkey: String,
        permissions: ClientPermissions,
        total: Int
    ) async throws {
        guard !resolvedSignerPubkey.isEmpty,
              let nsec = SharedKeychain.loadNsec(for: resolvedSignerPubkey) else {
            throw ClaveError.noSignerKey
        }
        let privateKey = try Bech32.decodeNsec(nsec)
        let signerPubkey = try LightEvent.pubkeyHex(from: privateKey)

        // Save client permissions
        SharedStorage.saveClientPermissions(permissions)

        guard !parsedURI.relays.isEmpty else {
            throw ClaveError.noRelay
        }
        guard let clientPubkeyData = Data(hexString: parsedURI.clientPubkey) else {
            throw ClaveError.invalidPubkey
        }

        // Connect to every URI relay in parallel, best-effort.
        let connectedRelays = await RelayUtils.connectToRelays(urls: parsedURI.relays, timeout: 10.0)
        defer {
            for relay in connectedRelays { relay.disconnect() }
        }

        // If zero relays connected, log the failure so the user sees it, then throw.
        if connectedRelays.isEmpty {
            let entry = ActivityEntry(
                id: UUID().uuidString,
                method: "connect",
                eventKind: nil,
                clientPubkey: parsedURI.clientPubkey,
                timestamp: Date().timeIntervalSince1970,
                status: "error",
                errorMessage: "Could not connect to any relay",
                signerPubkeyHex: signerPubkey
            )
            SharedStorage.logActivity(entry)
            throw ClaveError.noRelay
        }

        // Publish connect response with retry — ephemeral events (kind 24133) aren't
        // stored by relays, so the client must be subscribed at the moment we publish.
        // Retry up to 3 times with 2s gaps. We keep listening for the full window so
        // the client can finish its full RPC handshake (connect → get_public_key →
        // switch_relays) before we disconnect.
        var handshakeComplete = false
        var activityLogged = false
        var seenEventIds = Set<String>()

        for _ in 1...3 {
            // Build a fresh event each attempt (new created_at = new event ID)
            let responseId = UUID().uuidString
            // Resolve account profile for enriched JSON ack (multi only).
            // Single-account flow falls back to bare-secret string inside
            // LightSigner.connectAckResult.
            let account = accounts.first(where: { $0.pubkeyHex == signerPubkey })
            let resultField = LightSigner.connectAckResult(
                isMultiAccount: parsedURI.isMultiAccount,
                echoedSecret: parsedURI.secret,
                accountName: account?.profile?.displayName,
                accountPicture: account?.profile?.pictureURL,
                total: total
            )
            let responseDict: [String: Any] = ["id": responseId, "result": resultField]
            guard let responseData = try? JSONSerialization.data(withJSONObject: responseDict),
                  let responseJSON = String(data: responseData, encoding: .utf8) else {
                continue
            }
            let freshEncrypted = try LightCrypto.nip44Encrypt(
                privateKey: privateKey,
                publicKey: clientPubkeyData,
                plaintext: responseJSON
            )
            let connectEvent = try LightEvent.sign(
                privateKey: privateKey,
                kind: 24133,
                content: freshEncrypted,
                tags: [["p", parsedURI.clientPubkey]]
            )

            // Publish the connect response only until we see a reply. After that
            // we keep listening without republishing — the client is already paired
            // and we just need to service its follow-up RPCs (connect/ack,
            // get_public_key, switch_relays). Breaking early used to disconnect
            // before switch_relays could run, which stranded the client on the URI
            // relays instead of migrating it to relay.powr.build.
            if !handshakeComplete,
               let eventData = connectEvent.toJSON().data(using: .utf8),
               let eventDict = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any] {
                let acceptedCount = await RelayUtils.publishEventToRelays(connectedRelays, event: eventDict)

                if !activityLogged {
                    let success = acceptedCount > 0
                    let entry = ActivityEntry(
                        id: UUID().uuidString,
                        method: "connect",
                        eventKind: nil,
                        clientPubkey: parsedURI.clientPubkey,
                        timestamp: Date().timeIntervalSince1970,
                        status: success ? "signed" : "error",
                        errorMessage: success ? nil : "All relays rejected connect response",
                        signerPubkeyHex: signerPubkey
                    )
                    SharedStorage.logActivity(entry)
                    activityLogged = true

                    // Tell the proxy about this pair so it opens secondary subs
                    // on the URI relays. Best-effort — failures queue for retry
                    // via SharedStorage.pendingPairOps.
                    if success {
                        pairClientWithProxy(
                            clientPubkey: parsedURI.clientPubkey,
                            relayUrls: parsedURI.relays,
                            signer: signerPubkey
                        )
                    } else {
                        throw ClaveError.noRelay
                    }
                }
            }

            // Wait then check for client response across all connected relays.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let now = Int(Date().timeIntervalSince1970)
            let listenFilter: [String: Any] = [
                "kinds": [24133],
                "#p": [signerPubkey],
                "since": now - 10,
                "limit": 10
            ]
            let events = await RelayUtils.fetchEventsFromRelays(connectedRelays, filter: listenFilter, timeout: 3.0)
            for event in events {
                guard let eventId = event["id"] as? String, seenEventIds.insert(eventId).inserted else { continue }
                guard let pubkey = event["pubkey"] as? String,
                      pubkey == parsedURI.clientPubkey else { continue }
                let _ = try? await LightSigner.handleRequest(
                    privateKey: privateKey,
                    requestEvent: event,
                    responseRelays: connectedRelays
                )
                handshakeComplete = true
            }

            // Do NOT break on handshakeComplete — keep listening so the client
            // can finish its get_public_key + switch_relays RPC sequence. The
            // retry cap (3 iterations) bounds the total wait at ~15s.
        }
    }
}
