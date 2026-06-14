import Foundation

/// Pending-approval alert chain coordinator — extracted from AppState per the
/// AppState god-object refactor (Stage 4b). Owns the approve/deny lifecycle,
/// the alert-chain state machine (build 55–60 polish sprint), and the
/// lock-screen action static handler.
///
/// Lives in an extension because the methods read/write `@Observable` stored
/// state on AppState (`pendingRequests`, `dismissedAlertRequestIds`,
/// `processedInChain`). The `@Observable`-bound computed properties
/// (`freshPendingRequests`, `activeApprovalRequest`, `pendingApprovalQueueDepth`,
/// `chainPosition`, `chainTotal`) and stored properties remain in the main
/// AppState class declaration to preserve `@Observable` macro behavior intact
/// — same defensive pattern as Stage 3b's `var profile`.
extension AppState {

    /// Mark the currently-active approval request as alert-dismissed. The
    /// request stays in `pendingRequests` so the bell badge still reflects
    /// it; only the alert presentation is suppressed. Idempotent — no-op
    /// if no active request.
    ///
    /// Internal helper retained for testing and potential future per-request
    /// dismiss UI; the root alert's "Not now" button calls
    /// `dismissAllActiveAlerts` instead so a single tap escapes the whole
    /// batch (see method below for rationale).
    func dismissActiveAlert() {
        guard let id = activeApprovalRequest?.id else { return }
        dismissedAlertRequestIds.insert(id)
    }

    /// Mark every currently-fresh pending request as alert-dismissed in one
    /// pass. Called from the root alert's "Not now" button.
    ///
    /// Why dismiss all rather than just the active one: per-request
    /// dismissal would auto-chain to the next request's alert immediately
    /// — which is exactly the "alert keeps popping back up" UX the user
    /// originally complained about. "Not now" is a session-level defer
    /// ("handle the whole batch via the bell"), distinct from Approve /
    /// Deny which are per-request decisions.
    ///
    /// New requests arriving after this call still arm the alert because
    /// their ids aren't in the dismissed set.
    func dismissAllActiveAlerts() {
        for request in freshPendingRequests {
            dismissedAlertRequestIds.insert(request.id)
        }
        // Chain is closed by user — reset progress so the next chain
        // (when a new request arrives) starts at "1 of N" again.
        processedInChain = 0
    }

    func refreshPendingRequests() {
        // Read-only refresh: pull current on-disk state into the
        // @Observable property. Stale-entry purging is intentionally
        // NOT run here — `refreshPendingRequests` is also triggered by
        // the in-process `.pendingRequestsUpdated` observer, which fires
        // on every queue mutation including legacy/migration writes that
        // may use sentinel timestamps. The freshness filter at read time
        // (`freshPendingRequests` computed) keeps the UI clean; the hard
        // purge below runs from explicit user-active triggers
        // (MainTabView scenePhase `.active`) where stale-row eviction is
        // safe and desirable.
        pendingRequests = SharedStorage.getPendingRequests()
        // Defensive chain-counter reset: any path that empties the alert
        // chain (TTL purge clearing the active request, lock-screen
        // approve/deny while app is alive, multi-account switch, etc.)
        // funnels through `pendingRequests` mutation → this observer.
        // If no chain is active, processedInChain MUST be 0 so the next
        // chain (when a fresh request arrives) starts at "1 of N" again.
        if activeApprovalRequest == nil && processedInChain > 0 {
            processedInChain = 0
        }
    }

    /// Removes pending requests aged past `pendingRequestTTLSeconds` from
    /// `SharedStorage` and writes an `ActivityEntry` with status `"expired"`
    /// for each. Called from `refreshPendingRequests` (which runs on
    /// `.pendingRequestsUpdated`, scenePhase `.active`, and approve/deny).
    /// Idempotent: no-op when nothing is stale.
    ///
    /// Why a hard purge instead of a read-time filter only: the alert
    /// binding, bell badge, and inbox sheet all derive from
    /// `pendingRequests`. If we only filtered at read time, stale rows
    /// would persist on disk (visible to the next NSE wake, would cap
    /// the queue at 20, and lock-screen action handlers might still
    /// resolve them by id). Purging keeps storage and the UI in sync.
    func purgeStalePendingRequests() {
        let cutoff = Date().timeIntervalSince1970 - Self.pendingRequestTTLSeconds
        let onDisk = SharedStorage.getPendingRequests()
        let stale = onDisk.filter { $0.timestamp <= cutoff }
        guard !stale.isEmpty else { return }
        for request in stale {
            SharedStorage.removePendingRequest(id: request.id)
            PendingApprovalBanner.clear(requestId: request.id)
            let entry = ActivityEntry(
                id: UUID().uuidString,
                method: request.method,
                eventKind: request.eventKind,
                clientPubkey: request.clientPubkey,
                timestamp: Date().timeIntervalSince1970,
                status: "expired",
                errorMessage: "Request timed out before user response",
                signerPubkeyHex: request.signerPubkeyHex
            )
            SharedStorage.logActivity(entry)
        }
    }

    /// Set or clear a per-kind override on the (signer, client)
    /// permissions row. Called from `PendingRequestDetailView` when the
    /// user toggles "Always allow this kind from <client>". No-op if the
    /// permissions row doesn't exist (the client must already be paired).
    func setKindOverride(signer: String, client: String, kind: Int, allowed: Bool) {
        guard var perms = SharedStorage.getClientPermissions(signer: signer, client: client) else {
            return
        }
        perms.kindOverrides[kind] = allowed
        SharedStorage.saveClientPermissions(perms)
    }

    /// Outcome of an approve-pending-request attempt. Used by
    /// PendingApprovalsView to decide between success haptic, error alert, or
    /// keeping the pending row available for retry.
    enum ApproveOutcome: Equatable {
        case signed
        case failedKeepingPending(reason: String)
        case failedAndRemoved(reason: String)
    }

    /// Approve a pending request from inside the running app (inbox swipe,
    /// detail-view button, root alert). Thin delegate to the static
    /// `performApprove` helper plus chain-position advancement.
    ///
    /// On `.signed` or `.failedAndRemoved` outcomes the request is gone
    /// from `pendingRequests`, so the chain progresses one step. We pull
    /// fresh state synchronously (don't wait for the
    /// `.pendingRequestsUpdated` observer's main-queue dispatch) and bump
    /// `processedInChain` in the same actor block so the alert title
    /// re-evaluates atomically — without the sync, SwiftUI would briefly
    /// paint "X of total-1" before settling on "X of total".
    ///
    /// `.failedKeepingPending` keeps the request for retry, so the chain
    /// doesn't advance.
    func approvePendingRequest(_ request: PendingRequest) async -> ApproveOutcome {
        let outcome = await Self.performApprove(request)
        switch outcome {
        case .signed, .failedAndRemoved:
            advanceChainPosition()
        case .failedKeepingPending:
            break
        }
        return outcome
    }

    /// Deny a pending request from inside the running app. Like approve,
    /// advances the chain counter synchronously so the alert title
    /// re-evaluates atomically with the queue shrinkage.
    func denyPendingRequest(_ request: PendingRequest) {
        Self.performDeny(request)
        advanceChainPosition()
        // Tell the client its request was rejected so it shows a clean
        // rejection instead of hanging — NIP-46 clients keep a request
        // pending until a response arrives. Fire-and-forget so the alert
        // chain UI doesn't block on the relay round-trip; the running app
        // stays alive to finish the publish. (The lock-screen deny path
        // awaits this instead — see `handlePendingApprovalAction` — because
        // that process may be suspended before a detached send completes.)
        Task { await Self.sendDenyResponse(request) }
    }

    /// Synchronously refresh `pendingRequests` from `SharedStorage`,
    /// increment `processedInChain`, and reset on natural chain end.
    /// Called from approve/deny instance methods. Pulls state from
    /// `SharedStorage` directly because the `.pendingRequestsUpdated`
    /// observer's main-queue dispatch hasn't run yet at this point —
    /// without the explicit pull, `pendingRequests` would still hold
    /// the just-removed request when the title re-evaluates.
    private func advanceChainPosition() {
        pendingRequests = SharedStorage.getPendingRequests()
        processedInChain += 1
        // Natural chain end (queue drained or all remaining are dismissed)
        // resets the counter so the next chain starts fresh.
        if activeApprovalRequest == nil {
            processedInChain = 0
        }
    }

    /// Static entry point for the lock-screen Approve / Deny notification
    /// action handler. Safe to call from `AppDelegate` even during a cold
    /// launch where `AppState` (held by `ContentView`'s @State) may not
    /// have initialized yet — the work is done via `SharedStorage` +
    /// `LightSigner` directly. UI refresh on the running-app side is
    /// driven by `SharedStorage.removePendingRequest` posting
    /// `.pendingRequestsUpdated`, which `AppState`'s existing observer
    /// catches when alive.
    ///
    /// Looking up the request from storage by id (rather than passing a
    /// `PendingRequest` through `userInfo`) keeps the wire format simple:
    /// the notification only carries the id, the storage row carries the
    /// full record. Idempotent: if the request was already handled (in-app
    /// alert finished it, second action tap, expired purge), the lookup
    /// returns nil and we just clear any lingering banner.
    static func handlePendingApprovalAction(requestId: String, actionId: String) async {
        guard let request = SharedStorage.getPendingRequests().first(where: { $0.id == requestId }) else {
            PendingApprovalBanner.clear(requestId: requestId)
            return
        }
        switch actionId {
        case PendingApprovalCategory.approveActionId:
            _ = await performApprove(request)
        case PendingApprovalCategory.denyActionId:
            performDeny(request)
            // Awaited (not fire-and-forget) on the lock-screen path: this
            // handler runs from AppDelegate's notification-action callback,
            // and the process may be suspended the moment it returns, so the
            // rejection publish has to complete before we hand control back.
            await sendDenyResponse(request)
        default:
            break
        }
    }

    /// Approve a pending request: sign and publish the response.
    /// Task 5: loads by the request's signer pubkey (PendingRequest.signerPubkeyHex,
    /// added in Task 3); falls back to the current account for legacy rows
    /// (UserDefaults read so this works without an AppState instance).
    ///
    /// Failure handling: relay rejection of the response wrapper (transient
    /// drop, rate-limit, auth) keeps the pending row so the user can retry
    /// from the inbox. Hard failures (no nsec, malformed event JSON, decoder
    /// error) clear the row because retry can't succeed.
    static func performApprove(_ request: PendingRequest) async -> ApproveOutcome {
        let signer: String
        if !request.signerPubkeyHex.isEmpty {
            signer = request.signerPubkeyHex
        } else {
            signer = SharedConstants.sharedDefaults.string(
                forKey: SharedConstants.currentSignerPubkeyHexKey
            ) ?? ""
        }
        guard !signer.isEmpty,
              let nsec = SharedKeychain.loadNsec(for: signer) else {
            performRemovePending(request)
            return .failedAndRemoved(reason: "Signing key unavailable.")
        }

        let privateKey: Data
        do {
            privateKey = try Bech32.decodeNsec(nsec)
        } catch {
            performRemovePending(request)
            return .failedAndRemoved(reason: "Could not decode signing key.")
        }

        guard let data = request.requestEventJSON.data(using: .utf8),
              let requestEvent = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            performRemovePending(request)
            return .failedAndRemoved(reason: "Pending request data corrupted.")
        }

        do {
            let result = try await LightSigner.handleRequest(
                privateKey: privateKey,
                requestEvent: requestEvent,
                skipProtection: true,
                skipDedupe: true,
                responseRelayUrl: request.responseRelayUrl
            )
            if result.status == "signed" {
                performRemovePending(request)
                return .signed
            }
            let reason = result.errorMessage ?? "Relay did not accept the signed response. Try Approve again."
            return .failedKeepingPending(reason: reason)
        } catch {
            performRemovePending(request)
            return .failedAndRemoved(reason: error.localizedDescription)
        }
    }

    static func performDeny(_ request: PendingRequest) {
        performRemovePending(request)
    }

    /// Resolve the denied request's signer key and dispatch the NIP-46
    /// `{ error: "user rejected" }` rejection on the wire. Both the in-app
    /// deny (`denyPendingRequest`) and the lock-screen deny action funnel
    /// through here so the rejection is identical regardless of entry point.
    ///
    /// Key resolution mirrors `performApprove`: prefer the request's own
    /// `signerPubkeyHex` (so we sign as the account that received the request
    /// even if the active account has since switched — identity must not
    /// drift between request and response), falling back to the current
    /// account for legacy rows. Best-effort: returns silently if the key is
    /// unavailable, leaving the client to fall back to its own timeout.
    static func sendDenyResponse(_ request: PendingRequest) async {
        let signer: String
        if !request.signerPubkeyHex.isEmpty {
            signer = request.signerPubkeyHex
        } else {
            signer = SharedConstants.sharedDefaults.string(
                forKey: SharedConstants.currentSignerPubkeyHexKey
            ) ?? ""
        }
        guard !signer.isEmpty,
              let nsec = SharedKeychain.loadNsec(for: signer),
              let privateKey = try? Bech32.decodeNsec(nsec) else {
            return
        }
        await LightSigner.sendRejection(
            privateKey: privateKey,
            requestEventJSON: request.requestEventJSON,
            responseRelayUrl: request.responseRelayUrl
        )
    }

    private static func performRemovePending(_ request: PendingRequest) {
        SharedStorage.removePendingRequest(id: request.id)
        PendingApprovalBanner.clear(requestId: request.id)
    }
}
