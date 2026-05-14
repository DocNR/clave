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

    // Multi-account state. Account CRUD lives in
    // `Clave/AppState+AccountManager.swift`. These stored properties stay
    // here because Swift forbids stored properties in extensions.

    /// All accounts owned by this device. Populated by `loadAccounts()` from
    /// `accountsKey` UserDefaults; mutated by `addAccount` /
    /// `generateAccount` / `deleteAccount`.
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

    // MARK: - UI navigation state

    /// Selected `MainTabView` tab. Lives on AppState (not local `@State`)
    /// so sibling tabs can route between each other — e.g. `ConnectTabView`
    /// sets this to `.home` after a successful pairing so the user lands
    /// back on Home instead of staring at the Connect tab's camera
    /// viewfinder. Defaults to `.home` (the app's landing tab).
    var selectedTab: MainTab = .home

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
    var dismissedAlertRequestIds: Set<String> = []

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
    var processedInChain: Int = 0

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
    /// account (or after the user picks from ConnectAccountPicker). HomeView
    /// observes this to present ApprovalSheet.
    var pendingNostrconnectURI: NostrConnectParser.ParsedURI?

    /// Set when a nostrconnect:// deeplink arrives and the user has 2+
    /// accounts. HomeView observes this to present ConnectAccountPicker.
    var pendingDeeplinkAccountChoice: NostrConnectParser.ParsedURI?

    /// Pubkey of the account chosen by ConnectAccountPicker. Threaded
    /// through to ApprovalSheet via boundAccountPubkeys (wrapped in a
    /// 1-element array). Cleared after the connect completes or the
    /// user cancels.
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
    var bunkerSecretsTick: Int = 0


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


}
