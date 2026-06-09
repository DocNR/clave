import Foundation
import CryptoKit
import os.log

private let logger = Logger(subsystem: "dev.nostr.clave", category: "pair")

/// Proxy HTTP client — extracted from AppState per the AppState god-object
/// refactor (Stage 3c). Owns all NIP-98-signed POSTs to clave-proxy
/// (`/register`, `/unregister`, `/pair-client`, `/unpair-client`) plus the
/// pendingPairOps retry queue worker.
///
/// Lives in an extension because the methods read/write @Observable state
/// on AppState (`accounts`, `signerPubkeyHex`, `deviceToken`, `isKeyImported`).
/// The `[Pair]` Logger is file-scoped here (relocated from the AppState.swift
/// file-scope declaration) — multiple Logger instances with the same
/// subsystem+category combine into one log stream, so behavior is unchanged.
extension AppState {

    /// Register the current account's pubkey/token mapping with the proxy.
    /// Thin wrapper around `registerSignerWithProxy(signer:)` for callers
    /// in single-account contexts (Settings manual button, Onboarding flow,
    /// addAccount post-switch).
    func registerWithProxy(completion: ((Bool, String) -> Void)? = nil) {
        registerSignerWithProxy(signer: signerPubkeyHex, completion: completion)
    }

    /// Register every account's signer pubkey with the proxy. Each account
    /// needs an independent (deviceToken, signerPubkey) mapping so APNs can
    /// route incoming kind:24133 requests for any account, not just the
    /// currently-selected one. Without this, the proxy receives events for
    /// non-current account pubkeys and drops them with "no registered tokens"
    /// — surfaced during build 33 multi-account smoke test on real device.
    ///
    /// Idempotent on the proxy side. Fire-and-forget per-account; failures
    /// get retried on the next `ensureAllRegisteredFresh()` trigger or app
    /// launch. Per-signer throttle/cooldown state lives in
    /// `SharedStorage.lastRegisterTimes`.
    func registerAllAccountsWithProxy() {
        for account in accounts {
            registerSignerWithProxy(signer: account.pubkeyHex)
        }
    }

    /// Per-account register implementation. Loads the signer-specific nsec
    /// from Keychain, signs NIP-98 with that key, POSTs `/register` so the
    /// proxy stores `(deviceToken, signerPubkey)` for APNs routing. Records
    /// per-signer success/failure timestamps via `SharedStorage` so the
    /// throttled wrapper knows which accounts need a retry.
    private func registerSignerWithProxy(signer signerPubkeyHex: String, completion: ((Bool, String) -> Void)? = nil) {
        // Reload token from SharedDefaults in case it arrived after loadState()
        let token = SharedConstants.sharedDefaults.string(forKey: SharedConstants.deviceTokenKey) ?? ""
        if !token.isEmpty && deviceToken.isEmpty { deviceToken = token }

        guard !deviceToken.isEmpty else {
            completion?(false, "No device token")
            return
        }

        guard !signerPubkeyHex.isEmpty,
              let nsec = SharedKeychain.loadNsec(for: signerPubkeyHex) else {
            completion?(false, "No signer key")
            return
        }

        let privateKey: Data
        do {
            privateKey = try Bech32.decodeNsec(nsec)
        } catch {
            completion?(false, "Invalid signer key")
            return
        }

        let proxyURL = SharedConstants.sharedDefaults.string(forKey: SharedConstants.proxyURLKey)
            ?? SharedConstants.defaultProxyURL
        let registerURL = "\(proxyURL)/register"
        guard let url = URL(string: registerURL) else {
            completion?(false, "Invalid proxy URL")
            return
        }

        let bodyDict = ["token": deviceToken]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: bodyDict) else {
            completion?(false, "Body serialization failed")
            return
        }
        let bodyHash = SHA256.hash(data: bodyData).map { String(format: "%02x", $0) }.joined()

        let authHeader: String
        do {
            authHeader = try LightEvent.signNip98(
                privateKey: privateKey,
                url: registerURL,
                method: "POST",
                bodySha256Hex: bodyHash
            )
        } catch {
            completion?(false, "Auth signing failed: \(error.localizedDescription)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader, forHTTPHeaderField: "X-Clave-Auth")
        request.httpBody = bodyData

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                let now = Date().timeIntervalSince1970
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    SharedStorage.setLastRegisterSucceededAt(now, for: signerPubkeyHex)
                    self?.drainPendingPairOps()
                    completion?(true, "Registered")
                } else if let http = response as? HTTPURLResponse {
                    SharedStorage.setLastRegisterFailedAt(now, for: signerPubkeyHex)
                    completion?(false, "Failed: HTTP \(http.statusCode)")
                } else {
                    SharedStorage.setLastRegisterFailedAt(now, for: signerPubkeyHex)
                    completion?(false, error?.localizedDescription ?? "Connection failed")
                }
            }
        }.resume()
    }

    /// Throttled wrapper around `registerWithProxy()` for opportunistic
    /// re-register of the current account on app foreground. Skips if a
    /// recent success exists; gates retries after failure with a cooldown
    /// so a dead proxy doesn't get hammered. Idempotent on the proxy side
    /// regardless.
    ///
    /// Single-account variant; multi-account callers should prefer
    /// `ensureAllRegisteredFresh()`. Kept for callers that explicitly want
    /// current-only behavior.
    func ensureRegisteredFresh() {
        guard isKeyImported, !signerPubkeyHex.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        // Task 5: per-signer throttle/cooldown — each account tracks its
        // own register success/failure independently.
        let lastSuccess = SharedStorage.getLastRegisterSucceededAt(for: signerPubkeyHex) ?? 0
        let lastFailure = SharedStorage.getLastRegisterFailedAt(for: signerPubkeyHex) ?? 0

        // Skip if we successfully registered within the last 30 minutes.
        if lastSuccess > 0 && (now - lastSuccess) < 1800 { return }
        // Apply a 60-second cooldown between failed attempts to avoid hammering
        // a dead proxy (e.g., during a Cloudflare incident or local network blip).
        if lastFailure > 0 && (now - lastFailure) < 60 { return }

        registerWithProxy()
    }

    /// Multi-account variant of `ensureRegisteredFresh()`. On scene .active,
    /// iterates every account and registers any whose per-signer cooldown
    /// allows it. Each account has independent throttle state; one account's
    /// recent failure does not block another's retry.
    ///
    /// Trigger: `MainTabView.handleScenePhase(.active)`. Catches the case
    /// where a cold-launch register POST silently failed on bad cellular for
    /// one account and the user later moved to wifi.
    func ensureAllRegisteredFresh() {
        guard isKeyImported, !accounts.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        for account in accounts {
            let pk = account.pubkeyHex
            let lastSuccess = SharedStorage.getLastRegisterSucceededAt(for: pk) ?? 0
            let lastFailure = SharedStorage.getLastRegisterFailedAt(for: pk) ?? 0
            if lastSuccess > 0 && (now - lastSuccess) < 1800 { continue }
            if lastFailure > 0 && (now - lastFailure) < 60 { continue }
            registerSignerWithProxy(signer: pk)
        }
    }

    /// Unregister the current device token with the proxy. Called from
    /// `deleteAccount()` before clearing the keychain, so the nsec is
    /// still available for NIP-98 signing. Fire-and-forget — we don't
    /// block deleteAccount on the result.
    /// Unregister a signer's `(deviceToken, signerPubkey)` mapping with the proxy.
    /// Defaults to the current account; `deleteAccount` passes the to-be-deleted
    /// pubkey explicitly so the unregister is signed with the deleted account's
    /// nsec (still in Keychain at call-time per audit A2 ordering). Without this,
    /// deleting a non-current account left an orphan registration on the proxy
    /// — the deleted account's pubkey kept receiving APNs pushes that NSE
    /// silently dropped (no nsec to sign with).
    func unregisterWithProxy(signer: String? = nil) {
        let token = SharedConstants.sharedDefaults.string(forKey: SharedConstants.deviceTokenKey) ?? ""
        guard !token.isEmpty else { return }

        let signerToUse = signer ?? signerPubkeyHex
        guard !signerToUse.isEmpty,
              let nsec = SharedKeychain.loadNsec(for: signerToUse) else { return }
        let privateKey: Data
        do {
            privateKey = try Bech32.decodeNsec(nsec)
        } catch {
            return
        }

        let proxyURL = SharedConstants.sharedDefaults.string(forKey: SharedConstants.proxyURLKey)
            ?? SharedConstants.defaultProxyURL
        let unregisterURL = "\(proxyURL)/unregister"
        guard let url = URL(string: unregisterURL) else { return }

        let bodyDict = ["token": token]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: bodyDict) else { return }
        let bodyHash = SHA256.hash(data: bodyData).map { String(format: "%02x", $0) }.joined()

        let authHeader: String
        do {
            authHeader = try LightEvent.signNip98(
                privateKey: privateKey,
                url: unregisterURL,
                method: "POST",
                bodySha256Hex: bodyHash
            )
        } catch {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader, forHTTPHeaderField: "X-Clave-Auth")
        request.httpBody = bodyData

        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    // MARK: - Proxy per-client-relay (V2)

    /// Notify the proxy of a nostrconnect pair so it can open secondary relay
    /// subscriptions. Fire-and-forget from the caller's perspective; failures
    /// are queued in SharedStorage.pendingPairOps for later retry.
    func pairClientWithProxy(clientPubkey: String, relayUrls: [String], signer: String? = nil) {
        // Persist the client's URI relay set locally first (used by Layer 1's
        // foreground subscription). Idempotent.
        // Use the explicitly-provided signer (e.g. the current iteration of
        // runSingleConnect's multi-account loop, or deeplinkBoundAccount when
        // a deeplink pre-bound the URI) or fall back to the current account
        // — matching unpairClientWithProxy's pattern. Phase 2 callers in
        // AppState+NostrConnect.swift pass the loop's per-iteration signer.
        let resolvedSigner = signer ?? signerPubkeyHex
        logger.notice("[Pair] pair-client begin client=\(clientPubkey.prefix(8), privacy: .public) signer=\(resolvedSigner.prefix(8), privacy: .public) relays=\(relayUrls.count, privacy: .public)")
        SharedStorage.setClientRelayUrls(pubkey: clientPubkey, relayUrls: relayUrls, signer: resolvedSigner)

        // Layer 1: relay-set may have changed; refresh the foreground sub.
        Task { @MainActor in
            ForegroundRelaySubscription.shared.refreshRelaySet()
        }

        // Capture signer at call-time so the URLSession failure closure (which
        // may run after a user-driven account switch) enqueues the PairOp under
        // the correct account. Matches unpairClientWithProxy's capture pattern.
        let capturedSigner = resolvedSigner
        guard !capturedSigner.isEmpty,
              let nsec = SharedKeychain.loadNsec(for: capturedSigner) else {
            logger.error("[Pair] pair-client abort: empty signer or no nsec in Keychain client=\(clientPubkey.prefix(8), privacy: .public)")
            return
        }
        let privateKey: Data
        do {
            privateKey = try Bech32.decodeNsec(nsec)
        } catch {
            logger.error("[Pair] pair-client abort: Bech32 decode failed err=\(error.localizedDescription, privacy: .public)")
            return
        }

        let proxyURL = SharedConstants.sharedDefaults.string(forKey: SharedConstants.proxyURLKey)
            ?? SharedConstants.defaultProxyURL
        let pairURL = "\(proxyURL)/pair-client"
        guard let url = URL(string: pairURL) else {
            logger.error("[Pair] pair-client abort: invalid URL=\(pairURL, privacy: .public)")
            return
        }

        let bodyDict: [String: Any] = [
            "client_pubkey": clientPubkey,
            "relay_urls": relayUrls
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: bodyDict) else {
            logger.error("[Pair] pair-client abort: body serialization failed")
            return
        }
        let bodyHash = SHA256.hash(data: bodyData).map { String(format: "%02x", $0) }.joined()

        let authHeader: String
        do {
            authHeader = try LightEvent.signNip98(
                privateKey: privateKey,
                url: pairURL,
                method: "POST",
                bodySha256Hex: bodyHash
            )
        } catch {
            logger.error("[Pair] pair-client abort: NIP-98 sign failed err=\(error.localizedDescription, privacy: .public)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader, forHTTPHeaderField: "X-Clave-Auth")
        request.httpBody = bodyData

        URLSession.shared.dataTask(with: request) { _, response, error in
            let http = response as? HTTPURLResponse
            if http?.statusCode == 200 {
                logger.notice("[Pair] pair-client ok client=\(clientPubkey.prefix(8), privacy: .public) signer=\(capturedSigner.prefix(8), privacy: .public)")
                return
            }
            // Any non-200 (including network error → http == nil) queues for retry.
            let statusStr: String
            if let code = http?.statusCode {
                statusStr = "\(code)"
            } else if let error {
                statusStr = "net-err:\(error.localizedDescription)"
            } else {
                statusStr = "no-response"
            }
            logger.error("[Pair] pair-client failed status=\(statusStr, privacy: .public) — queued for retry client=\(clientPubkey.prefix(8), privacy: .public)")
            let op = PairOp(
                id: UUID().uuidString,
                kind: .pair,
                clientPubkey: clientPubkey,
                relayUrls: relayUrls,
                createdAt: Date().timeIntervalSince1970,
                failCount: 0,
                signerPubkeyHex: capturedSigner
            )
            SharedStorage.enqueuePendingPairOp(op)
        }.resume()
    }

    /// Notify the proxy of an unpair. Same failure semantics as pair.
    /// Unpair a (signer, client) pair from the proxy. Defaults to the current
    /// account; `deleteAccount` passes the to-be-deleted pubkey explicitly so
    /// the unpair targets the right (signer, client) row on the proxy. Without
    /// this, deleting a non-current account left orphan pair entries on the
    /// proxy that kept secondary-relay subscriptions open — proxy-side resource
    /// leak surfaced during build 33 multi-account smoke test as
    /// "no pair found" log noise during pendingPairOps drains.
    func unpairClientWithProxy(clientPubkey: String, signer: String? = nil) {
        // Layer 1: the unpaired client's URI relays may no longer be needed in
        // the foreground sub's set. Refresh.
        Task { @MainActor in
            ForegroundRelaySubscription.shared.refreshRelaySet()
        }
        // Capture signer at call-time (default current) so the retry enqueue
        // lands under the correct account even if an account switch races.
        let capturedSigner = signer ?? signerPubkeyHex
        logger.notice("[Pair] unpair-client begin client=\(clientPubkey.prefix(8), privacy: .public) signer=\(capturedSigner.prefix(8), privacy: .public)")
        Task {
            await LightSigner.unpairClientAndQueue(clientPubkey: clientPubkey, signer: capturedSigner)
        }
    }

    /// Drain the pending pair/unpair ops queue. Called on app foreground and
    /// after successful /register. Each op is retried once per drain attempt;
    /// ops that fail 3 times are removed.
    func drainPendingPairOps() {
        let ops = SharedStorage.getPendingPairOps()
        guard !ops.isEmpty else { return }
        for op in ops {
            if op.failCount >= 3 {
                SharedStorage.removePendingPairOp(id: op.id)
                continue
            }
            switch op.kind {
            case .pair:
                if let relays = op.relayUrls {
                    retryPairOp(op: op, relayUrls: relays)
                } else {
                    SharedStorage.removePendingPairOp(id: op.id)
                }
            case .unpair:
                retryUnpairOp(op: op)
            }
        }
    }

    private func retryPairOp(op: PairOp, relayUrls: [String]) {
        // Task 5: each PairOp now carries signerPubkeyHex (Task 3).
        // Fall back to current account for legacy ops written pre-Task-3.
        let signer = op.signerPubkeyHex.isEmpty ? signerPubkeyHex : op.signerPubkeyHex
        // No-nsec / setup-failure early returns: remove the op rather than let it
        // sit forever. A PairOp without a signable key is meaningless — the op
        // was queued before a key rotation or delete.
        guard !signer.isEmpty,
              let nsec = SharedKeychain.loadNsec(for: signer) else {
            SharedStorage.removePendingPairOp(id: op.id)
            return
        }
        let privateKey: Data
        do { privateKey = try Bech32.decodeNsec(nsec) } catch {
            SharedStorage.removePendingPairOp(id: op.id)
            return
        }

        let proxyURL = SharedConstants.sharedDefaults.string(forKey: SharedConstants.proxyURLKey)
            ?? SharedConstants.defaultProxyURL
        let pairURL = "\(proxyURL)/pair-client"
        guard let url = URL(string: pairURL) else {
            SharedStorage.removePendingPairOp(id: op.id)
            return
        }

        let bodyDict: [String: Any] = [
            "client_pubkey": op.clientPubkey,
            "relay_urls": relayUrls
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: bodyDict) else {
            SharedStorage.removePendingPairOp(id: op.id)
            return
        }
        let bodyHash = SHA256.hash(data: bodyData).map { String(format: "%02x", $0) }.joined()

        let authHeader: String
        do {
            authHeader = try LightEvent.signNip98(
                privateKey: privateKey,
                url: pairURL,
                method: "POST",
                bodySha256Hex: bodyHash
            )
        } catch {
            SharedStorage.bumpPendingPairOpFailCount(id: op.id)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader, forHTTPHeaderField: "X-Clave-Auth")
        request.httpBody = bodyData

        URLSession.shared.dataTask(with: request) { _, response, _ in
            let http = response as? HTTPURLResponse
            if http?.statusCode == 200 {
                SharedStorage.removePendingPairOp(id: op.id)
            } else {
                SharedStorage.bumpPendingPairOpFailCount(id: op.id)
            }
        }.resume()
    }

    private func retryUnpairOp(op: PairOp) {
        // Task 5: scope by op's signer (Task 3 added field), with current
        // fallback for legacy queue entries.
        let signer = op.signerPubkeyHex.isEmpty ? signerPubkeyHex : op.signerPubkeyHex
        guard !signer.isEmpty,
              let nsec = SharedKeychain.loadNsec(for: signer) else {
            SharedStorage.removePendingPairOp(id: op.id)
            return
        }
        let privateKey: Data
        do { privateKey = try Bech32.decodeNsec(nsec) } catch {
            SharedStorage.removePendingPairOp(id: op.id)
            return
        }

        let proxyURL = SharedConstants.sharedDefaults.string(forKey: SharedConstants.proxyURLKey)
            ?? SharedConstants.defaultProxyURL
        let unpairURL = "\(proxyURL)/unpair-client"
        guard let url = URL(string: unpairURL) else {
            SharedStorage.removePendingPairOp(id: op.id)
            return
        }

        let bodyDict: [String: Any] = ["client_pubkey": op.clientPubkey]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: bodyDict) else {
            SharedStorage.removePendingPairOp(id: op.id)
            return
        }
        let bodyHash = SHA256.hash(data: bodyData).map { String(format: "%02x", $0) }.joined()

        let authHeader: String
        do {
            authHeader = try LightEvent.signNip98(
                privateKey: privateKey,
                url: unpairURL,
                method: "POST",
                bodySha256Hex: bodyHash
            )
        } catch {
            SharedStorage.bumpPendingPairOpFailCount(id: op.id)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader, forHTTPHeaderField: "X-Clave-Auth")
        request.httpBody = bodyData

        URLSession.shared.dataTask(with: request) { _, response, _ in
            let http = response as? HTTPURLResponse
            if http?.statusCode == 200 {
                SharedStorage.removePendingPairOp(id: op.id)
            } else {
                SharedStorage.bumpPendingPairOpFailCount(id: op.id)
            }
        }.resume()
    }
}
