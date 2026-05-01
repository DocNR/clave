import Foundation
import CryptoKit
import NostrSDK
import Observation
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
    /// is provided via `updateCurrentProfile(_:)` which writes through to
    /// the accounts list and persists.
    var profile: CachedProfile? {
        currentAccount?.profile
    }

    var isKeyImported: Bool { currentAccount != nil }
    var deviceToken = ""
    var pendingRequests: [PendingRequest] = []
    var profileImage: UIImage?

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
            if self.isKeyImported {
                self.registerWithProxy()
            }
        }
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

    var bunkerURI: String {
        guard !signerPubkeyHex.isEmpty else { return "" }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":/")
        let relay = SharedConstants.relayURL
            .addingPercentEncoding(withAllowedCharacters: allowed) ?? SharedConstants.relayURL
        // Always read the latest secret from SharedStorage (NSE may have rotated it)
        let currentSecret = SharedStorage.getBunkerSecret(for: signerPubkeyHex)
        return "bunker://\(signerPubkeyHex)?relay=\(relay)&secret=\(currentSecret)"
    }

    func loadState() {
        // 1. One-shot bootstrap of build-31 single-account state into
        //    multi-account format. After this runs, the legacy Keychain
        //    entry is gone and the new pubkey-keyed entry exists. No-op
        //    on subsequent launches.
        bootstrapFromLegacyKeychainIfNeeded()

        // 2. Hydrate the accounts list + currentAccount from UserDefaults.
        loadAccounts()

        // 3. Defensive sweep — handles the rare race where bootstrap's
        //    saveNsec(for:) succeeded but the legacy deleteNsec() failed
        //    on a previous launch. Idempotent: usually a no-op.
        cleanupOrphanLegacyKeychainEntry()

        // 4. Load cached profile from disk (currentAccount.profile is the
        //    primary source post-Task-8; this still reads the legacy
        //    cachedProfileKey for now, populating profileImage).
        loadCachedProfileImage()

        deviceToken = SharedConstants.sharedDefaults.string(forKey: SharedConstants.deviceTokenKey) ?? ""

        // 5. Re-register with the proxy on every launch when both a key and a
        //    token are present. Belt to the suspenders of the
        //    .apnsDeviceTokenAvailable observer in init: this catches the
        //    ordering case where iOS handed us the device token *before* loadState
        //    ran (so the observer's `if isKeyImported` check failed at that moment
        //    because the key hadn't been loaded from Keychain yet). Idempotent on
        //    the proxy side.
        if isKeyImported && !deviceToken.isEmpty {
            registerWithProxy()
        }
    }

    // MARK: - Multi-account loading + bootstrap (Task 5)

    /// One-shot bootstrap: if accountsKey is empty AND a legacy
    /// `kSecAttrAccount = "signer-nsec"` Keychain entry exists, copy the
    /// nsec to the new pubkey-keyed entry, delete the legacy entry, and
    /// seed accountsKey + currentSignerPubkeyHexKey. Build-31 testers
    /// upgrade transparently with no re-import / no re-pair / no lost
    /// nsec.
    ///
    /// SECURITY (audit 2026-04-30): scope-limited memory exposure of
    /// `legacyNsec` String matches the existing importKey/loadState
    /// pattern; not a regression. No log line interpolates `legacyNsec`
    /// or any nsec-derived data — only the pubkey prefix.
    private func bootstrapFromLegacyKeychainIfNeeded() {
        let defaults = SharedConstants.sharedDefaults
        guard defaults.data(forKey: SharedConstants.accountsKey) == nil else {
            return  // Already in multi-account format; bootstrap not needed
        }
        guard let legacyNsec = SharedKeychain.loadNsec(),
              let keys = try? Keys.parse(secretKey: legacyNsec) else {
            return  // Fresh install; OnboardingView will show
        }

        let pubkeyHex = keys.publicKey().toHex()

        // Copy to new pubkey-keyed slot BEFORE deleting legacy. If the
        // save fails, leave legacy in place for retry on next launch
        // (idempotent — the accountsKey guard above stays unmet).
        do {
            try SharedKeychain.saveNsec(legacyNsec, for: pubkeyHex)
        } catch {
            // Don't proceed; legacy entry preserved
            return
        }

        // Delete legacy. Failure here means the orphan persists; the
        // every-launch cleanup pass (cleanupOrphanLegacyKeychainEntry)
        // catches it on next launch.
        SharedKeychain.deleteNsec()

        // Seed multi-account state.
        let account = Account(
            pubkeyHex: pubkeyHex,
            petname: nil,
            addedAt: Date().timeIntervalSince1970,
            profile: nil  // Refreshed by fetchProfileIfNeeded on next launch
        )
        persistAccountsList([account])
        defaults.set(pubkeyHex, forKey: SharedConstants.currentSignerPubkeyHexKey)
        // Keep legacy signerPubkeyHexKey in sync — still read by
        // ForegroundRelaySubscription.swift:354 until Task 6 ships.
        defaults.set(pubkeyHex, forKey: SharedConstants.signerPubkeyHexKey)
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
    /// Keychain entry still exists, the bootstrap's delete must have
    /// failed previously. Retry the delete idempotently.
    private func cleanupOrphanLegacyKeychainEntry() {
        guard !accounts.isEmpty,
              SharedKeychain.loadNsec() != nil else { return }
        SharedKeychain.deleteNsec()
    }

    /// Replaces `loadCachedProfile()` — only loads the on-disk image cache
    /// (profile metadata is now sourced from `currentAccount.profile`).
    /// Profile image filename is per-pubkey (Task 8 will move existing
    /// `profile_image.jpg` to per-pubkey naming); for now we read the
    /// legacy file path which still works for the migrated single account.
    private func loadCachedProfileImage() {
        if let imageData = try? Data(contentsOf: cachedImageURL),
           let image = UIImage(data: imageData) {
            profileImage = image
        }
    }

    private func persistAccountsList(_ list: [Account]) {
        accounts = list
        if let data = try? JSONEncoder().encode(list) {
            SharedConstants.sharedDefaults.set(data, forKey: SharedConstants.accountsKey)
        }
    }

    private func persistAccounts() {
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

        // Already in accounts? Just switch + return.
        if let existing = accounts.first(where: { $0.pubkeyHex == pubkeyHex }) {
            switchToAccount(pubkey: pubkeyHex)
            return existing
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
        //    NIP-98 signing.
        let clientsToUnpair = SharedStorage.getConnectedClients(for: pubkey)
        for client in clientsToUnpair {
            unpairClientWithProxy(clientPubkey: client.pubkey)
        }
        // Drop any pending pair ops for this signer (proxy will GC its rows).
        let pairOpsToDrop = SharedStorage.getPendingPairOps(for: pubkey)
        for op in pairOpsToDrop {
            SharedStorage.removePendingPairOp(id: op.id)
        }

        // 2. Unregister this account from the proxy.
        unregisterWithProxy()

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

        // 6. Remove cached profile image file (per-pubkey naming would be
        //    Task 8 work; for now the global file is shared across
        //    deletions in the rare multi-account-then-delete-current case).
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

    /// Write through to the current account's profile (for fetchProfile
    /// path). Updates `accounts` list + persists.
    private func updateCurrentProfile(_ profile: CachedProfile?) {
        guard let pk = currentAccount?.pubkeyHex,
              let idx = accounts.firstIndex(where: { $0.pubkeyHex == pk }) else { return }
        accounts[idx] = Account(
            pubkeyHex: accounts[idx].pubkeyHex,
            petname: accounts[idx].petname,
            addedAt: accounts[idx].addedAt,
            profile: profile
        )
        currentAccount = accounts[idx]
        persistAccounts()
    }

    // `loadCachedProfile()` and `saveCachedProfile(_:)` removed in Task 5.
    // Profile metadata now lives inside `currentAccount.profile`
    // (persisted via `persistAccounts()` → `accountsKey`). The legacy
    // `cachedProfileKey` UserDefaults entry is no longer the source of
    // truth; Task 8 will explicitly remove it as part of full migration.
    // Profile image still loads from disk via `loadCachedProfileImage()`
    // (called from loadState).

    private var cachedImageURL: URL {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedConstants.appGroup)!
        return container.appendingPathComponent("profile_image.jpg")
    }

    private func cacheImage(from urlString: String) async {
        guard let url = URL(string: urlString) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else { return }
            try data.write(to: cachedImageURL)
            await MainActor.run {
                self.profileImage = image
            }
        } catch {
            // Silently fail
        }
    }

    /// Fetch kind 0 profile from multiple relays in parallel. First valid result wins.
    /// Writes through to `currentAccount.profile` and persists the
    /// accounts list (Task 5: replaces the previous global
    /// `cachedProfileKey` write).
    func fetchProfileIfNeeded() {
        let pubkey = signerPubkeyHex
        guard !pubkey.isEmpty else { return }

        // Only refetch if cache is older than 1 hour
        if let existing = profile, Date().timeIntervalSince1970 - existing.fetchedAt < 3600 { return }

        let relays = [
            "wss://relay.powr.build",
            "wss://relay.damus.io",
            "wss://nos.lol",
            "wss://relay.primal.net",
            "wss://purplepag.es"
        ]

        Task {
            await withTaskGroup(of: CachedProfile?.self) { group in
                for url in relays {
                    group.addTask {
                        await Self.fetchProfile(from: url, pubkey: pubkey)
                    }
                }

                // Pick the most-recent profile across all relays (kind:0 is replaceable, latest wins)
                var newest: CachedProfile?
                for await result in group {
                    guard let result else { continue }
                    if newest == nil { newest = result; continue }
                    // Prefer the one with a picture if the other doesn't have one
                    if newest?.pictureURL == nil && result.pictureURL != nil { newest = result }
                }

                guard let cached = newest else { return }

                await MainActor.run {
                    // Only update if the user hasn't switched accounts mid-fetch
                    guard self.currentAccount?.pubkeyHex == pubkey else { return }
                    self.updateCurrentProfile(cached)
                }

                if let pic = cached.pictureURL, !pic.isEmpty {
                    await cacheImage(from: pic)
                }
            }
        }
    }

    private static func fetchProfile(from relayURL: String, pubkey: String) async -> CachedProfile? {
        do {
            let relay = LightRelay(url: relayURL)
            try await relay.connect(timeout: 5.0)
            defer { relay.disconnect() }

            let filter: [String: Any] = [
                "kinds": [0],
                "authors": [pubkey],
                "limit": 1
            ]

            let events = try await relay.fetchEvents(filter: filter, timeout: 5.0)

            guard let event = events.first,
                  let content = event["content"] as? String,
                  let contentData = content.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any] else {
                return nil
            }

            let displayName = (json["display_name"] as? String) ?? (json["name"] as? String)
            let pictureURL = json["picture"] as? String

            // Skip empty profiles (no name AND no picture)
            if (displayName?.isEmpty ?? true) && (pictureURL?.isEmpty ?? true) {
                return nil
            }

            return CachedProfile(
                displayName: displayName,
                pictureURL: pictureURL,
                fetchedAt: Date().timeIntervalSince1970
            )
        } catch {
            return nil
        }
    }

    func rotateBunkerSecret() {
        guard !signerPubkeyHex.isEmpty else { return }
        _ = SharedStorage.rotateBunkerSecret(for: signerPubkeyHex)
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
        pendingRequests = SharedStorage.getPendingRequests()
    }

    /// `bunkerURI` getter reads SharedStorage directly each access. This
    /// helper is now a no-op kept for source-compat with any caller; was
    /// previously a manual cache reload (the cache was removed in Task 5).
    func refreshBunkerSecret() {
        // No-op: bunkerURI reads SharedStorage on every access now.
    }

    /// Approve a pending request: sign and publish the response from the app.
    /// Task 5: load by the request's signer pubkey (PendingRequest.signerPubkeyHex,
    /// added in Task 3). Falls back to current account for legacy rows or when
    /// the request was queued without a signer (pre-Task-3 NSE writes).
    func approvePendingRequest(_ request: PendingRequest) async -> Bool {
        let signer = request.signerPubkeyHex.isEmpty ? signerPubkeyHex : request.signerPubkeyHex
        guard !signer.isEmpty,
              let nsec = SharedKeychain.loadNsec(for: signer) else { return false }

        let privateKey: Data
        do {
            privateKey = try Bech32.decodeNsec(nsec)
        } catch {
            return false
        }

        // Reconstruct the request event dict from stored JSON
        guard let data = request.requestEventJSON.data(using: .utf8),
              let requestEvent = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        do {
            let result = try await LightSigner.handleRequest(
                privateKey: privateKey,
                requestEvent: requestEvent,
                skipProtection: true,
                skipDedupe: true,
                responseRelayUrl: request.responseRelayUrl
            )
            SharedStorage.removePendingRequest(id: request.id)
            PendingApprovalBanner.clear(requestId: request.id)
            refreshPendingRequests()
            return result.status == "signed"
        } catch {
            return false
        }
    }

    func denyPendingRequest(_ request: PendingRequest) {
        SharedStorage.removePendingRequest(id: request.id)
        PendingApprovalBanner.clear(requestId: request.id)
        refreshPendingRequests()
    }

    /// Perform the nostrconnect:// handshake across all relays listed in the URI.
    /// Why multi-relay: the client (per NIP-46) subscribes on every relay in its URI;
    /// if we publish to only one and that relay drops the ephemeral kind:24133,
    /// the client never sees our response. Publishing to all is best-effort — we
    /// don't fail if some relays reject or are unreachable, we just need at least one.
    func handleNostrConnect(
        parsedURI: NostrConnectParser.ParsedURI,
        permissions: ClientPermissions
    ) async throws {
        // Task 5: handleNostrConnect uses the current account (the user
        // is in the UI explicitly accepting the pairing).
        guard !signerPubkeyHex.isEmpty,
              let nsec = SharedKeychain.loadNsec(for: signerPubkeyHex) else {
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
        let connectedRelays = await connectToRelays(urls: parsedURI.relays, timeout: 10.0)
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
                errorMessage: "Could not connect to any relay"
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
            let responseDict: [String: Any] = ["id": responseId, "result": parsedURI.secret]
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
                let acceptedCount = await publishEventToRelays(connectedRelays, event: eventDict)

                if !activityLogged {
                    let success = acceptedCount > 0
                    let entry = ActivityEntry(
                        id: UUID().uuidString,
                        method: "connect",
                        eventKind: nil,
                        clientPubkey: parsedURI.clientPubkey,
                        timestamp: Date().timeIntervalSince1970,
                        status: success ? "signed" : "error",
                        errorMessage: success ? nil : "All relays rejected connect response"
                    )
                    SharedStorage.logActivity(entry)
                    activityLogged = true

                    // Tell the proxy about this pair so it opens secondary subs
                    // on the URI relays. Best-effort — failures queue for retry
                    // via SharedStorage.pendingPairOps.
                    if success {
                        pairClientWithProxy(
                            clientPubkey: parsedURI.clientPubkey,
                            relayUrls: parsedURI.relays
                        )
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
            let events = await fetchEventsFromRelays(connectedRelays, filter: listenFilter, timeout: 3.0)
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

    func registerWithProxy(completion: ((Bool, String) -> Void)? = nil) {
        // Reload token from SharedDefaults in case it arrived after loadState()
        let token = SharedConstants.sharedDefaults.string(forKey: SharedConstants.deviceTokenKey) ?? ""
        if !token.isEmpty && deviceToken.isEmpty { deviceToken = token }

        guard !deviceToken.isEmpty else {
            completion?(false, "No device token")
            return
        }

        // Task 5: load the current account's nsec (multi-account world
        // would call this with an explicit signer parameter; Phase 1
        // ships single-account UI, so currentAccount is the source).
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

        // Capture signer for the closure — derived properties are
        // accessed at completion time, but currentAccount may have
        // changed by then, so freeze the value used to make this request.
        let signerForTimestamp = signerPubkeyHex
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                let now = Date().timeIntervalSince1970
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    SharedStorage.setLastRegisterSucceededAt(now, for: signerForTimestamp)
                    self?.drainPendingPairOps()
                    completion?(true, "Registered")
                } else if let http = response as? HTTPURLResponse {
                    SharedStorage.setLastRegisterFailedAt(now, for: signerForTimestamp)
                    completion?(false, "Failed: HTTP \(http.statusCode)")
                } else {
                    SharedStorage.setLastRegisterFailedAt(now, for: signerForTimestamp)
                    completion?(false, error?.localizedDescription ?? "Connection failed")
                }
            }
        }.resume()
    }

    /// Throttled wrapper around `registerWithProxy()` for opportunistic
    /// re-register on app foreground. Skips if a recent success exists; gates
    /// retries after failure with a cooldown so a dead proxy doesn't get
    /// hammered. Idempotent on the proxy side regardless.
    ///
    /// Trigger: `MainTabView.handleScenePhase(.active)`. Catches the case where
    /// the cold-launch register POST silently failed on bad cellular and the
    /// user later moved to wifi — without this, they had to tap Settings →
    /// Register manually (real tester report 2026-04-28).
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

    /// Unregister the current device token with the proxy. Called from
    /// `deleteAccount()` before clearing the keychain, so the nsec is
    /// still available for NIP-98 signing. Fire-and-forget — we don't
    /// block deleteAccount on the result.
    func unregisterWithProxy() {
        let token = SharedConstants.sharedDefaults.string(forKey: SharedConstants.deviceTokenKey) ?? ""
        guard !token.isEmpty else { return }

        guard !signerPubkeyHex.isEmpty,
              let nsec = SharedKeychain.loadNsec(for: signerPubkeyHex) else { return }
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
    func pairClientWithProxy(clientPubkey: String, relayUrls: [String]) {
        // Persist the client's URI relay set locally first (used by Layer 1's
        // foreground subscription). Idempotent.
        SharedStorage.setClientRelayUrls(pubkey: clientPubkey, relayUrls: relayUrls)

        // Layer 1: relay-set may have changed; refresh the foreground sub.
        Task { @MainActor in
            ForegroundRelaySubscription.shared.refreshRelaySet()
        }

        // Task 5: pair on behalf of the current account.
        guard !signerPubkeyHex.isEmpty,
              let nsec = SharedKeychain.loadNsec(for: signerPubkeyHex) else { return }
        let privateKey: Data
        do {
            privateKey = try Bech32.decodeNsec(nsec)
        } catch {
            return
        }

        let proxyURL = SharedConstants.sharedDefaults.string(forKey: SharedConstants.proxyURLKey)
            ?? SharedConstants.defaultProxyURL
        let pairURL = "\(proxyURL)/pair-client"
        guard let url = URL(string: pairURL) else { return }

        let bodyDict: [String: Any] = [
            "client_pubkey": clientPubkey,
            "relay_urls": relayUrls
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: bodyDict) else { return }
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
            if http?.statusCode == 200 { return }
            // Any non-200 (including network error → http == nil) queues for retry.
            let op = PairOp(
                id: UUID().uuidString,
                kind: .pair,
                clientPubkey: clientPubkey,
                relayUrls: relayUrls,
                createdAt: Date().timeIntervalSince1970,
                failCount: 0
            )
            SharedStorage.enqueuePendingPairOp(op)
        }.resume()
    }

    /// Notify the proxy of an unpair. Same failure semantics as pair.
    func unpairClientWithProxy(clientPubkey: String) {
        // Layer 1: the unpaired client's URI relays may no longer be needed
        // in the foreground sub's set. Refresh.
        Task { @MainActor in
            ForegroundRelaySubscription.shared.refreshRelaySet()
        }

        // Task 5: unpair on behalf of the current account.
        guard !signerPubkeyHex.isEmpty,
              let nsec = SharedKeychain.loadNsec(for: signerPubkeyHex) else { return }
        let privateKey: Data
        do {
            privateKey = try Bech32.decodeNsec(nsec)
        } catch {
            return
        }

        let proxyURL = SharedConstants.sharedDefaults.string(forKey: SharedConstants.proxyURLKey)
            ?? SharedConstants.defaultProxyURL
        let unpairURL = "\(proxyURL)/unpair-client"
        guard let url = URL(string: unpairURL) else { return }

        let bodyDict: [String: Any] = ["client_pubkey": clientPubkey]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: bodyDict) else { return }
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
            if http?.statusCode == 200 { return }
            let op = PairOp(
                id: UUID().uuidString,
                kind: .unpair,
                clientPubkey: clientPubkey,
                relayUrls: nil,
                createdAt: Date().timeIntervalSince1970,
                failCount: 0
            )
            SharedStorage.enqueuePendingPairOp(op)
        }.resume()
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

    // MARK: - Multi-relay helpers (nostrconnect handshake)

    /// Connect to multiple relays in parallel, best-effort.
    /// Returns only the relays that connected successfully within the timeout.
    /// Failures are silently dropped so one unreachable relay never blocks the others.
    private func connectToRelays(urls: [String], timeout: TimeInterval) async -> [LightRelay] {
        await withTaskGroup(of: LightRelay?.self) { group in
            for url in urls {
                group.addTask {
                    let relay = LightRelay(url: url)
                    do {
                        try await relay.connect(timeout: timeout)
                        return relay
                    } catch {
                        return nil
                    }
                }
            }
            var connected: [LightRelay] = []
            for await maybe in group {
                if let relay = maybe { connected.append(relay) }
            }
            return connected
        }
    }

    /// Publish the same event to all connected relays in parallel.
    /// Returns the number of relays that returned `OK true`.
    private func publishEventToRelays(_ relays: [LightRelay], event: [String: Any]) async -> Int {
        await withTaskGroup(of: Bool.self) { group in
            for relay in relays {
                group.addTask {
                    (try? await relay.publishEvent(event: event)) ?? false
                }
            }
            var accepted = 0
            for await ok in group {
                if ok { accepted += 1 }
            }
            return accepted
        }
    }

    /// Fetch events matching the filter from all connected relays in parallel.
    /// Aggregates results; duplicates by event id are NOT removed (caller should handle).
    private func fetchEventsFromRelays(
        _ relays: [LightRelay],
        filter: [String: Any],
        timeout: TimeInterval
    ) async -> [[String: Any]] {
        await withTaskGroup(of: [[String: Any]].self) { group in
            for relay in relays {
                group.addTask {
                    (try? await relay.fetchEvents(filter: filter, timeout: timeout)) ?? []
                }
            }
            var all: [[String: Any]] = []
            for await events in group {
                all.append(contentsOf: events)
            }
            return all
        }
    }

    // MARK: - Test-only shims

    #if DEBUG
    func _testOnlyConnectToRelays(urls: [String], timeout: TimeInterval) async -> [LightRelay] {
        await connectToRelays(urls: urls, timeout: timeout)
    }
    func _testOnlyPublishEventToRelays(_ relays: [LightRelay], event: [String: Any]) async -> Int {
        await publishEventToRelays(relays, event: event)
    }
    func _testOnlyFetchEventsFromRelays(_ relays: [LightRelay], filter: [String: Any], timeout: TimeInterval) async -> [[String: Any]] {
        await fetchEventsFromRelays(relays, filter: filter, timeout: timeout)
    }
    #endif
}
