import Foundation
import CryptoKit
import NostrSDK
import Observation
import os.log
import UIKit

enum ClaveError: LocalizedError {
    case noSignerKey
    case noRelay
    case serializationFailed
    case invalidPubkey

    var errorDescription: String? {
        switch self {
        case .noSignerKey: return "No signer key configured"
        case .noRelay: return "No relay specified"
        case .serializationFailed: return "Failed to build response"
        case .invalidPubkey: return "Invalid client public key"
        }
    }
}

// `CachedProfile` extracted to Shared/SharedModels.swift on 2026-04-30
// (feat/multi-account, Task 1) so multi-account code in Shared/ can
// reference it. Field shape preserved; existing UserDefaults rows decode
// identically.

@Observable
final class AppState {
    // MARK: - Multi-account state (Task 5)

    /// All accounts owned by this device. Populated by `loadAccounts()` from
    /// `accountsKey` UserDefaults; mutated by `addAccount` /
    /// `generateAccount` / `deleteAccount` / `renamePetname`.
    var accounts: [Account] = []

    /// The current account scope for the UI. Stays synchronized with
    /// `currentSignerPubkeyHexKey` UserDefaults. NSE never reads this — NSE
    /// routes via the APNs payload pubkey (Task 6).
    var currentAccount: Account?

    /// Hex pubkey of the current account, derived. Empty string means no
    /// current account (no key imported / fresh install). Source-compat
    /// shim: existing call sites read this property; was a stored
    /// property before Task 5.
    var signerPubkeyHex: String { currentAccount?.pubkeyHex ?? "" }

    /// kind:0 profile metadata for the current account, derived. Setter
    /// is provided via `updateCurrentProfile(_:)` (lives in
    /// `Clave/AppState+ProfileFetcher.swift`) which writes through to
    /// the accounts list and persists.
    var profile: CachedProfile? {
        currentAccount?.profile
    }

    var isKeyImported: Bool { currentAccount != nil }
    var deviceToken = ""
    var pendingRequests: [PendingRequest] = []

    /// Cached profile image. Loaded by `loadCachedProfileImage()` and
    /// updated by `cacheImage(...)` — both in
    /// `Clave/AppState+ProfileFetcher.swift`. Stays here because Swift
    /// forbids stored properties in extensions.
    var profileImage: UIImage?

    // MARK: - Pending approval surface (root alert + inbox bell)
    //
    // `pendingRequests` is the on-disk source of truth (cap 20, written by
    // NSE and L1). For the in-app approval UI we want a freshness filter
    // so that requests aged past the typical NIP-46 client timeout are
    // never surfaced — clients have long since given up listening for the
    // signed response, and approving a stale request would publish a
    // useless event to the relay. `pendingRequestTTLSeconds` is the cutoff;
    // `purgeStalePendingRequests` is the active cleanup that also writes
    // an "expired" ActivityEntry so the user has a record.
    static let pendingRequestTTLSeconds: Double = 300  // 5 minutes

    /// Pending requests whose `timestamp` is within the TTL window. Read by
    /// the root alert binding, the bell badge, and the inbox sheet. SwiftUI
    /// re-evaluates whenever `pendingRequests` mutates (Observation tracks
    /// the read of the stored property).
    var freshPendingRequests: [PendingRequest] {
        let cutoff = Date().timeIntervalSince1970 - Self.pendingRequestTTLSeconds
        return pendingRequests.filter { $0.timestamp > cutoff }
    }

    /// In-memory set of pending request ids the user has dismissed via the
    /// root alert's "Not now" button (or any non-Approve/Deny dismissal —
    /// e.g. system-driven dismissal during navigation). Filtered out of
    /// `activeApprovalRequest` so the alert doesn't infinite-loop on every
    /// view re-evaluation. The bell badge / inbox sheet still surface the
    /// dismissed requests via `pendingApprovalQueueDepth` and
    /// `freshPendingRequests` — "Not now" means *handle this via the bell*,
    /// not *throw it away*.
    ///
    /// Resets on app relaunch (in-memory only). New requests arriving after
    /// dismissal still trigger the alert because their ids aren't in this
    /// set. Dismissed-then-approved/denied/expired ids stay in the set but
    /// are harmless — the underlying request is gone from `pendingRequests`
    /// so the filter has nothing to skip past.
    private var dismissedAlertRequestIds: Set<String> = []

    /// First fresh pending request whose alert has not been dismissed —
    /// drives `MainTabView`'s root alert. Auto-chains: when the user
    /// approves/denies the active request, SwiftUI re-evaluates this and
    /// presents the next undismissed fresh request. When all fresh
    /// requests are dismissed, returns nil and the alert stays closed
    /// until a new request arrives.
    var activeApprovalRequest: PendingRequest? {
        freshPendingRequests.first { !dismissedAlertRequestIds.contains($0.id) }
    }

    /// Count for the bell-badge + alert title "(N of M)" suffix. Counts ALL
    /// fresh pending requests, including ones the user has dismissed from
    /// the alert — they're still pending, just being handled via the bell.
    var pendingApprovalQueueDepth: Int {
        freshPendingRequests.count
    }

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

    // MARK: - Alert chain position tracking
    //
    // The root alert's title shows "X of N" so the user knows how deep
    // the queue is. Pre-build-59 the format was "1 of <queueDepth>",
    // which always read "1" and used the *remaining* count — so a chain
    // of 3 went 1-of-3 → 1-of-2 → 1-of-1 instead of the expected
    // 1-of-3 → 2-of-3 → 3-of-3.
    //
    // Fix: track a `processedInChain` counter that increments on each
    // approve/deny and resets when the chain ends. Position is
    // `processedInChain + 1`; total is current fresh count plus already-
    // processed (so new requests arriving mid-chain bump the total —
    // 2-of-3 with R4 incoming becomes 2-of-4).

    /// Number of requests already approved/denied within the current
    /// chain. Resets to 0 when the chain ends (`activeApprovalRequest`
    /// becomes nil), when "Not now" closes the batch, or whenever
    /// `refreshPendingRequests` observes that no chain is active. The
    /// reset is defensive — multiple paths can end a chain (TTL purge,
    /// lock-screen action while app alive, dismissAll), and we don't
    /// want stale progress carrying into the next chain.
    private(set) var processedInChain: Int = 0

    /// 1-based position of the active request within the current chain.
    /// Used in the root alert's title. Always >= 1 when
    /// `activeApprovalRequest` is non-nil. Undefined-but-harmless when
    /// no chain is active (UI doesn't show the title in that state).
    var chainPosition: Int {
        processedInChain + 1
    }

    /// Total chain size for the title. Sums (fresh AND non-dismissed)
    /// remaining + already processed so new requests arriving mid-chain
    /// naturally bump the total. Filtering out dismissed requests is
    /// critical: after "Not now" closes a batch and a fresh request
    /// arrives, the new chain is "1 of 1" — not "1 of N" where N
    /// includes the just-dismissed batch.
    var chainTotal: Int {
        let visibleRemaining = freshPendingRequests.filter {
            !dismissedAlertRequestIds.contains($0.id)
        }
        return visibleRemaining.count + processedInChain
    }

    /// Set by long-press on a strip pill; consumed by HomeView's
    /// NavigationStack to push AccountDetailView for that account without
    /// switching active. Cleared after navigation fires.
    var pendingDetailPubkey: String?

    // NostrConnect deeplink state. Set by handleDeeplink and consumed by
    // handleNostrConnect — both live in `Clave/AppState+NostrConnect.swift`.
    // These stay here because Swift forbids stored properties in extensions.

    /// Set when a nostrconnect:// deeplink arrives and the user has only one
    /// account (or after the user picks from DeeplinkAccountPicker). HomeView
    /// observes this to present ApprovalSheet.
    var pendingNostrconnectURI: NostrConnectParser.ParsedURI?

    /// Set when a nostrconnect:// deeplink arrives and the user has 2+
    /// accounts. HomeView observes this to present DeeplinkAccountPicker.
    var pendingDeeplinkAccountChoice: NostrConnectParser.ParsedURI?

    /// Pubkey of the account chosen by DeeplinkAccountPicker. Threaded
    /// through to ApprovalSheet via boundAccountPubkey. Cleared after
    /// the connect completes or the user cancels.
    var deeplinkBoundAccount: String?

    init() {
        // Drain the /pair-client retry queue on every app foreground. The
        // AppDelegate posts .drainPendingPairOps from applicationDidBecomeActive.
        NotificationCenter.default.addObserver(
            forName: .drainPendingPairOps,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.drainPendingPairOps()
        }

        // Refresh the pending-requests list whenever any code path mutates
        // it (L1 foreground sub queue, approve/deny, future code). NSE-side
        // writes don't cross the process boundary; the MainTabView scenePhase
        // observer handles those by refreshing on app foreground.
        NotificationCenter.default.addObserver(
            forName: .pendingRequestsUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshPendingRequests()
        }

        // Re-register with the proxy whenever iOS hands us a device token.
        // Catches three real-world failure modes that previously left users
        // silently unable to receive push-wakes:
        //  1. iOS rotated the token (Apple does this periodically, especially
        //     after iOS upgrades) — proxy was holding a stale token.
        //  2. The user reinstalled Clave from TestFlight — fresh install gets
        //     a new token, but the existing nsec in Keychain means we never
        //     hit the importKey/generateKey re-register path.
        //  3. The proxy lost our token entry (e.g. the tokens.json migration
        //     wiped legacy entries; future bug we haven't hit yet) — re-
        //     registering on launch transparently recovers.
        // Idempotent on the proxy side (upsert), so harmless on the common
        // case where token+pubkey haven't changed.
        NotificationCenter.default.addObserver(
            forName: .apnsDeviceTokenAvailable,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            if let token = note.object as? String {
                self.deviceToken = token
            }
            // Only register if we already have a key. Onboarding flow handles
            // the no-key-yet case via the explicit `importKey()` /
            // `generateKey()` path; no point trying with no nsec to sign.
            // Register every account so APNs can route to any of them (Bug B
            // fix: pre-build-34 only registered current account, leaving
            // non-current accounts unreachable for background signing).
            if self.isKeyImported {
                self.registerAllAccountsWithProxy()
            }
        }

        // Route incoming deeplink URLs (nostrconnect://, clave://) to the
        // appropriate pending state. ClaveApp.onOpenURL posts this notification;
        // handleDeeplink (Task 3.3) uses DeeplinkRouter to set either
        // pendingNostrconnectURI (single-account path) or
        // pendingDeeplinkAccountChoice (multi-account picker path).
        NotificationCenter.default.addObserver(
            forName: .deeplinkReceived,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let url = note.object as? URL else { return }
            Task { @MainActor in
                self?.handleDeeplink(url: url)
            }
        }

        // Lock-screen Approve / Deny actions are handled directly in
        // `AppDelegate.userNotificationCenter(_:didReceive:)` via
        // `AppState.handlePendingApprovalAction(requestId:actionId:)` —
        // a static path that doesn't require an `AppState` instance.
        // That's deliberate: when iOS launches the app cold to handle
        // a notification action, the SwiftUI view tree (and `AppState`)
        // hasn't initialized yet, so a NotificationCenter-based
        // dispatcher would lose the post. The static path does the
        // SharedStorage + LightSigner work directly; this `AppState`
        // (when alive) sees the pending row removal via the
        // `.pendingRequestsUpdated` observer above and refreshes
        // automatically.
    }

    // MARK: - Foreground subscription bridge

    /// Bridges into the `@MainActor`-isolated ForegroundRelaySubscription. Called
    /// from a SwiftUI scenePhase observer in the root view. AppState itself is
    /// not `@MainActor`, so the hop happens here.
    @MainActor
    func startForegroundSubscription() {
        ForegroundRelaySubscription.shared.start()
    }

    @MainActor
    func stopForegroundSubscription() {
        ForegroundRelaySubscription.shared.stop()
    }

    var npub: String {
        guard !signerPubkeyHex.isEmpty,
              let pubkey = try? PublicKey.parse(publicKey: signerPubkeyHex) else { return "" }
        return (try? pubkey.toBech32()) ?? ""
    }

    // `bunkerSecret` removed in Task 5 — was a stored cache mirroring
    // `SharedStorage.getBunkerSecret(for:)`. Zero view callers; all reads
    // now go through `bunkerURI` (which calls SharedStorage directly) so
    // the cache adds no value.

    /// Increments on every `rotateBunkerSecret()` call so SwiftUI views
    /// observing this property re-evaluate `bunkerURI` (a computed property
    /// reading from SharedStorage / UserDefaults — which @Observable can't
    /// track on its own). Read with a discarded `let _ = appState.bunkerSecretsTick`
    /// in the view's body to establish the observation dependency.
    private(set) var bunkerSecretsTick: Int = 0

    var bunkerURI: String {
        bunkerURI(for: signerPubkeyHex) ?? ""
    }

    /// Per-account variant of `bunkerURI`. Returns the bunker URI for the
    /// given signer pubkey, or nil if either the pubkey is empty or no bunker
    /// secret has been initialized for that account.
    ///
    /// Same construction as the single-account `bunkerURI` computed property,
    /// which now delegates to this method.
    func bunkerURI(for pubkey: String) -> String? {
        guard !pubkey.isEmpty else { return nil }
        let secret = SharedStorage.getBunkerSecret(for: pubkey)
        guard !secret.isEmpty else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":/")
        let relay = SharedConstants.relayURL
            .addingPercentEncoding(withAllowedCharacters: allowed) ?? SharedConstants.relayURL
        return "bunker://\(pubkey)?relay=\(relay)&secret=\(secret)"
    }

    func loadState() {
        // 1. Hydrate the accounts list + currentAccount from UserDefaults.
        loadAccounts()

        // 2. Reinstall recovery: if accountsKey is empty AND Keychain has
        //    pubkey-keyed entries, reconstruct minimum Account records
        //    from Keychain. Handles the rare iOS Storage-settings
        //    UserDefaults wipe (Apple-documented) where Keychain persisted.
        recoverAccountsFromKeychainIfNeeded()

        // 3. Defensive sweep for any orphan legacy Keychain entry left
        //    over from a build-31-era bootstrap that failed mid-flight.
        //    Idempotent and a no-op for fresh installs and any user
        //    already in current-format state.
        cleanupOrphanLegacyKeychainEntry()

        // 4. Load cached profile image from disk for the current account.
        loadCachedProfileImage()

        deviceToken = SharedConstants.sharedDefaults.string(forKey: SharedConstants.deviceTokenKey) ?? ""

        // 5. Re-register with the proxy on every launch when both a key and a
        //    token are present. Belt to the suspenders of the
        //    .apnsDeviceTokenAvailable observer in init: this catches the
        //    ordering case where iOS handed us the device token *before* loadState
        //    ran (so the observer's `if isKeyImported` check failed at that moment
        //    because the key hadn't been loaded from Keychain yet). Idempotent on
        //    the proxy side. Multi-account: registers every account on launch so
        //    APNs can route to any of them.
        if isKeyImported && !deviceToken.isEmpty {
            registerAllAccountsWithProxy()
        }
    }

    /// Reconstruct minimum Account records from Keychain when accountsKey
    /// is empty but pubkey-keyed Keychain entries exist. Covers the case
    /// where iOS Storage settings wiped UserDefaults but Keychain
    /// persisted (rare but real — Apple's documentation calls this out).
    /// Profile metadata is nil; refreshes on next foreground.
    private func recoverAccountsFromKeychainIfNeeded() {
        let defaults = SharedConstants.sharedDefaults
        guard defaults.data(forKey: SharedConstants.accountsKey) == nil else { return }
        let pubkeys = SharedKeychain.listAllPubkeys()
        guard !pubkeys.isEmpty else { return }

        let now = Date().timeIntervalSince1970
        let recovered = pubkeys.map {
            Account(pubkeyHex: $0, petname: nil, addedAt: now, profile: nil)
        }
        persistAccountsList(recovered)
        // First pubkey becomes current. User can switch via UI later.
        if let firstPubkey = pubkeys.first {
            defaults.set(firstPubkey, forKey: SharedConstants.currentSignerPubkeyHexKey)
            defaults.set(firstPubkey, forKey: SharedConstants.signerPubkeyHexKey)
            currentAccount = recovered.first
        }
        accounts = recovered
    }

    /// Hydrate `accounts` + `currentAccount` from UserDefaults.
    private func loadAccounts() {
        let defaults = SharedConstants.sharedDefaults
        if let data = defaults.data(forKey: SharedConstants.accountsKey),
           let decoded = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = decoded
        } else {
            accounts = []
        }
        let currentHex = defaults.string(forKey: SharedConstants.currentSignerPubkeyHexKey) ?? ""
        currentAccount = accounts.first { $0.pubkeyHex == currentHex } ?? accounts.first
        // Persist back if we picked a different one (current pointer was
        // stale because the named account got deleted out from under us).
        if currentAccount?.pubkeyHex != currentHex {
            persistCurrentAccountPubkey()
        }
    }

    /// Defensive: if accounts.count >= 1 AND the legacy fixed-account
    /// Keychain entry still exists, a prior build-31-era bootstrap's
    /// delete must have failed. Retry the delete idempotently.
    ///
    /// Sunset candidate — the bootstrap that could create new orphans
    /// was removed, so this only catches pre-existing orphans. Safe
    /// to delete after a few build cycles confirm zero observed orphans
    /// (or if telemetry shows the legacy keychain entry is consistently
    /// absent across all installs).
    private func cleanupOrphanLegacyKeychainEntry() {
        guard !accounts.isEmpty,
              SharedKeychain.loadNsec() != nil else { return }
        SharedKeychain.deleteNsec()
    }

    private func persistAccountsList(_ list: [Account]) {
        accounts = list
        if let data = try? JSONEncoder().encode(list) {
            SharedConstants.sharedDefaults.set(data, forKey: SharedConstants.accountsKey)
        }
    }

    func persistAccounts() {
        persistAccountsList(accounts)
    }

    private func persistCurrentAccountPubkey() {
        let pk = currentAccount?.pubkeyHex ?? ""
        let defaults = SharedConstants.sharedDefaults
        defaults.set(pk, forKey: SharedConstants.currentSignerPubkeyHexKey)
        // Legacy key write-through — read by ForegroundRelaySubscription.swift:354
        // until Task 6 updates that callsite.
        defaults.set(pk, forKey: SharedConstants.signerPubkeyHexKey)
    }

    // MARK: - Multi-account methods (Task 5)

    /// Switch the UI scope to a different account. No-op if pubkey isn't
    /// in the accounts list. Synchronous and cheap — the heavy work
    /// (profile refresh, etc.) happens via existing observers.
    func switchToAccount(pubkey: String) {
        guard let next = accounts.first(where: { $0.pubkeyHex == pubkey }) else { return }
        currentAccount = next
        persistCurrentAccountPubkey()
        // Bug G fix: clear stale image and reload from the new account's
        // on-disk cache, then opportunistically fetch (1-hour cooldown).
        // Without this, `profileImage` stayed bound to the previous
        // account's PFP across switches because loadCachedProfileImage()
        // was only invoked at app cold-launch — producing the visible
        // "wrong avatar persists across account switches" symptom.
        profileImage = nil
        loadCachedProfileImage()
        fetchProfileIfNeeded()
    }

    /// Add an account by pasting an nsec. Idempotent: if the same nsec
    /// is added twice, switches to the existing account and returns it
    /// (matches noauth's silent dedupe; Phase 2 UI surfaces a toast).
    @discardableResult
    func addAccount(nsec: String, petname: String? = nil) throws -> Account {
        let trimmed = nsec.trimmingCharacters(in: .whitespacesAndNewlines)
        let keys = try Keys.parse(secretKey: trimmed)
        let bech32 = try keys.secretKey().toBech32()
        let pubkeyHex = keys.publicKey().toHex()

        // Already in accounts? Just switch + return. (Dedupe wins over cap;
        // re-pasting an existing nsec is never a NEW account.)
        if let existing = accounts.first(where: { $0.pubkeyHex == pubkeyHex }) {
            switchToAccount(pubkey: pubkeyHex)
            return existing
        }

        // Cap check for NEW accounts only. UI layer pre-checks for the
        // Generate flow; this guard catches Paste-nsec and any future caller.
        guard accounts.count < Account.maxAccountsPerDevice else {
            throw AccountError.accountCapReached
        }

        // Save to Keychain first — if this fails, no UserDefaults rows
        // get written.
        try SharedKeychain.saveNsec(bech32, for: pubkeyHex)

        let sanitizedPetname = sanitizePetname(petname)
        let account = Account(
            pubkeyHex: pubkeyHex,
            petname: sanitizedPetname,
            addedAt: Date().timeIntervalSince1970,
            profile: nil
        )
        accounts.append(account)
        persistAccounts()

        currentAccount = account
        persistCurrentAccountPubkey()

        // Bug G fix: clear stale image from previous account so the UI
        // doesn't show the wrong avatar between switch and fetch completion.
        // The new account has no cached image yet (just created), so
        // loadCachedProfileImage is a no-op; fetchProfileIfNeeded will
        // populate once the relay reply arrives.
        profileImage = nil

        // Async: register this account's pubkey with the proxy + fetch
        // kind:0 profile. Fire-and-forget.
        registerWithProxy()
        fetchProfileIfNeeded()

        return account
    }

    /// Generate a fresh keypair as a new account.
    @discardableResult
    func generateAccount(petname: String? = nil) throws -> Account {
        let keys = Keys.generate()
        let bech32 = try keys.secretKey().toBech32()
        return try addAccount(nsec: bech32, petname: petname)
    }

    /// Delete an account from this device. Audit 2026-04-30 finding A2:
    /// ordering is unpair-clients FIRST (still has nsec) → Keychain
    /// delete → bunker secret cleanup → records cleanup → accountsKey
    /// write. If interrupted mid-way, the worst case is a visible
    /// Account row that fails to load — recoverable by re-deleting.
    func deleteAccount(pubkey: String) {
        // 1. Unpair this account's clients with the proxy. Best-effort —
        //    failures enqueue retry. Keychain entry must still exist for
        //    NIP-98 signing. Bug D fix: pass `signer: pubkey` so the unpair
        //    is signed with the to-be-deleted account's nsec, targeting the
        //    correct (signer, client) row on the proxy. Without this, the
        //    unpair signed with current's nsec hit `(signer=current, client=X)`
        //    which doesn't exist → 200 "no pair found" → proxy keeps the real
        //    `(signer=deleted, client=X)` row as an orphan.
        let clientsToUnpair = SharedStorage.getConnectedClients(for: pubkey)
        for client in clientsToUnpair {
            unpairClientWithProxy(clientPubkey: client.pubkey, signer: pubkey)
        }
        // Drop any pending pair ops for this signer (proxy will GC its rows).
        let pairOpsToDrop = SharedStorage.getPendingPairOps(for: pubkey)
        for op in pairOpsToDrop {
            SharedStorage.removePendingPairOp(id: op.id)
        }

        // 2. Unregister this account from the proxy. Bug D fix: explicit
        //    signer ensures the unregister is auth'd by the to-be-deleted
        //    account, removing its (token, deletedPubkey) mapping. Without
        //    this, a deleted non-current account stayed registered on the
        //    proxy and kept receiving APNs pushes the device couldn't action.
        unregisterWithProxy(signer: pubkey)

        // 3. Delete Keychain entry.
        SharedKeychain.deleteNsec(for: pubkey)

        // 4. Remove this signer's bunker secret from the per-signer dict.
        //    rotateBunkerSecret(for:) overwrites with random — equivalent
        //    to deletion for security purposes (the old secret can't be
        //    recovered) but leaves an unused entry. Acceptable hygiene.
        _ = SharedStorage.rotateBunkerSecret(for: pubkey)

        // 5. Remove this account's records — scoped, NEVER touches other
        //    accounts' rows.
        SharedStorage.unpairAllClients(for: pubkey)
        // Filter activity / pending / pendingPairOps by signer
        var activity = SharedStorage.getActivityLog()
        activity.removeAll { $0.signerPubkeyHex == pubkey }
        // Save back via direct UserDefaults write (no public scoped activity-clear API)
        if let data = try? JSONEncoder().encode(activity) {
            SharedConstants.sharedDefaults.set(data, forKey: SharedConstants.activityLogKey)
        }
        var pending = SharedStorage.getPendingRequests()
        pending.removeAll { $0.signerPubkeyHex == pubkey }
        if let data = try? JSONEncoder().encode(pending) {
            SharedConstants.sharedDefaults.set(data, forKey: SharedConstants.pendingRequestsKey)
        }

        // 6. Remove cached profile image file. Bug F3 fix: also delete the
        //    per-pubkey cache file. Without this, deleted accounts left
        //    `cached-profile-<pubkey>.dat` orphans on disk forever.
        try? FileManager.default.removeItem(at: cachedImageURL(for: pubkey))
        // Defensive: also sweep any pre-multi-account `profile_image.jpg`
        // orphan from the build-31 era. Idempotent no-op for fresh installs.
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedConstants.appGroup)
        if let imageURL = container?.appendingPathComponent("profile_image.jpg") {
            try? FileManager.default.removeItem(at: imageURL)
        }

        // 7. Remove from accounts list, persist accountsKey.
        accounts.removeAll { $0.pubkeyHex == pubkey }
        persistAccounts()

        // 8. Auto-switch or clear current.
        if currentAccount?.pubkeyHex == pubkey {
            currentAccount = accounts.first
            persistCurrentAccountPubkey()
            // In-memory state belongs to the deleted account; clear it.
            profileImage = nil
            pendingRequests = []
        }
    }

    /// Edit the petname for an account. Audit 2026-04-30 finding A3:
    /// trim whitespace + strip newlines + cap at 64 chars to prevent
    /// control-char injection into log lines / notification bodies and
    /// DoS via huge strings.
    func renamePetname(for pubkey: String, to petname: String?) {
        guard let idx = accounts.firstIndex(where: { $0.pubkeyHex == pubkey }) else { return }
        accounts[idx] = Account(
            pubkeyHex: accounts[idx].pubkeyHex,
            petname: sanitizePetname(petname),
            addedAt: accounts[idx].addedAt,
            profile: accounts[idx].profile
        )
        persistAccounts()
        if currentAccount?.pubkeyHex == pubkey {
            currentAccount = accounts[idx]
        }
    }

    private func sanitizePetname(_ petname: String?) -> String? {
        guard let petname else { return nil }
        let normalized = petname
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isNewline }
        let capped = String(normalized.prefix(64))
        return capped.isEmpty ? nil : capped
    }

    func rotateBunkerSecret() {
        guard !signerPubkeyHex.isEmpty else { return }
        _ = SharedStorage.rotateBunkerSecret(for: signerPubkeyHex)
        bunkerSecretsTick &+= 1
    }

    // Legacy wrappers — preserved for OnboardingView and SettingsView call
    // sites. Phase 2 UI will call addAccount/generateAccount/deleteAccount
    // directly.

    func importKey(nsec: String) throws {
        _ = try addAccount(nsec: nsec, petname: nil)
    }

    func generateKey() throws {
        _ = try generateAccount(petname: nil)
    }

    func deleteKey() {
        guard let pubkey = currentAccount?.pubkeyHex else { return }
        deleteAccount(pubkey: pubkey)
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

    /// `bunkerURI` getter reads SharedStorage directly each access. This
    /// helper is now a no-op kept for source-compat with any caller; was
    /// previously a manual cache reload (the cache was removed in Task 5).
    func refreshBunkerSecret() {
        // No-op: bunkerURI reads SharedStorage on every access now.
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

    private static func performRemovePending(_ request: PendingRequest) {
        SharedStorage.removePendingRequest(id: request.id)
        PendingApprovalBanner.clear(requestId: request.id)
    }


}
