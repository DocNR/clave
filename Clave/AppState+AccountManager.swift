import Foundation
import NostrSDK

/// Account management — extracted from AppState per the AppState god-object
/// refactor (Stage 4a). Owns the account list lifecycle: hydration from
/// UserDefaults, reinstall recovery, persistence, switch / add / generate /
/// delete, bunker URI construction + secret rotation, and the legacy
/// `importKey` / `generateKey` / `deleteKey` wrappers preserved for
/// `OnboardingView` / `SettingsView` callers.
///
/// Lives in an extension because the methods read/write `@Observable` stored
/// state on AppState (`accounts`, `currentAccount`, `bunkerSecretsTick`,
/// `profileImage`, `pendingRequests`). Stored properties remain in the main
/// AppState class declaration.
///
/// Cross-extension calls within Stage 4a's surface (e.g. `addAccount` calling
/// `registerWithProxy` from Stage 3c, `fetchProfileIfNeeded` from Stage 3b,
/// `loadCachedProfileImage` from Stage 3b) all resolve via extension dispatch
/// on the same AppState type.
extension AppState {

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

    /// Reconstruct minimum Account records from Keychain when accountsKey
    /// is empty but pubkey-keyed Keychain entries exist. Covers the case
    /// where iOS Storage settings wiped UserDefaults but Keychain
    /// persisted (rare but real — Apple's documentation calls this out).
    /// Profile metadata is nil; refreshes on next foreground.
    func recoverAccountsFromKeychainIfNeeded() {
        let defaults = SharedConstants.sharedDefaults
        guard defaults.data(forKey: SharedConstants.accountsKey) == nil else { return }
        let pubkeys = SharedKeychain.listAllPubkeys()
        guard !pubkeys.isEmpty else { return }

        let now = Date().timeIntervalSince1970
        let recovered = pubkeys.map {
            Account(pubkeyHex: $0, addedAt: now, profile: nil)
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
    func loadAccounts() {
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
    func cleanupOrphanLegacyKeychainEntry() {
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
    func addAccount(nsec: String) throws -> Account {
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

        let account = Account(
            pubkeyHex: pubkeyHex,
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
    func generateAccount() throws -> Account {
        let keys = Keys.generate()
        let bech32 = try keys.secretKey().toBech32()
        return try addAccount(nsec: bech32)
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

    func rotateBunkerSecret() {
        rotateBunkerSecret(for: signerPubkeyHex)
    }

    /// Per-signer variant of `rotateBunkerSecret()`. Rotates the bunker
    /// secret for an explicit signer rather than the current account.
    /// No-ops silently when the pubkey doesn't correspond to a known account.
    func rotateBunkerSecret(for pubkey: String) {
        guard !pubkey.isEmpty,
              accounts.contains(where: { $0.pubkeyHex == pubkey }) else { return }
        _ = SharedStorage.rotateBunkerSecret(for: pubkey)
        bunkerSecretsTick &+= 1
    }

    // Legacy wrappers — preserved for OnboardingView and SettingsView call
    // sites. Phase 2 UI will call addAccount/generateAccount/deleteAccount
    // directly.

    func importKey(nsec: String) throws {
        _ = try addAccount(nsec: nsec)
    }

    func generateKey() throws {
        _ = try generateAccount()
    }

    func deleteKey() {
        guard let pubkey = currentAccount?.pubkeyHex else { return }
        deleteAccount(pubkey: pubkey)
    }

    /// `bunkerURI` getter reads SharedStorage directly each access. This
    /// helper is now a no-op kept for source-compat with any caller; was
    /// previously a manual cache reload (the cache was removed in Task 5).
    func refreshBunkerSecret() {
        // No-op: bunkerURI reads SharedStorage on every access now.
    }
}
