import Foundation
import UIKit

/// Profile metadata + image fetching, caching, and merging — extracted
/// from AppState per the AppState god-object refactor (Stage 3b).
///
/// Lives in an extension because the methods read/write @Observable state
/// on AppState (`accounts`, `currentAccount`, `profileImage`) and call
/// `persistAccounts()` (will move out in Stage 4 with AccountManager).
/// The `var profile` and `var profileImage` properties remain on the main
/// AppState class declaration to keep `@Observable` macro behavior intact
/// (computed property safety + stored property requirement respectively).
extension AppState {

    /// Loads the on-disk image cache for the current account. Profile
    /// metadata itself is sourced from `currentAccount.profile`. Image
    /// filename is per-pubkey via the `cachedImageURL` computed property.
    func loadCachedProfileImage() {
        if let imageData = try? Data(contentsOf: cachedImageURL),
           let image = UIImage(data: imageData) {
            profileImage = image
        }
    }

    /// Write through to the current account's profile (for fetchProfile
    /// path). Updates `accounts` list + persists.
    private func updateCurrentProfile(_ profile: CachedProfile?) {
        guard let pk = currentAccount?.pubkeyHex,
              let idx = accounts.firstIndex(where: { $0.pubkeyHex == pk }) else { return }
        accounts[idx] = Account(
            pubkeyHex: accounts[idx].pubkeyHex,
            addedAt: accounts[idx].addedAt,
            profile: profile
        )
        currentAccount = accounts[idx]
        persistAccounts()
    }

    /// Per-pubkey on-disk profile image cache path. File extension is
    /// `.dat` (not `.jpg`) because we don't enforce the source
    /// content-type — the relay-fetched image could be PNG, WebP, etc.
    func cachedImageURL(for pubkeyHex: String) -> URL {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedConstants.appGroup)!
        return container.appendingPathComponent("cached-profile-\(pubkeyHex).dat")
    }

    /// Convenience accessor for the current account's image path.
    /// Returns a URL even if currentAccount is nil (uses empty pubkey),
    /// callers should guard before reading.
    private var cachedImageURL: URL {
        cachedImageURL(for: signerPubkeyHex)
    }

    /// Download a profile image and write it to the per-account cache file.
    /// Bug F fix: takes an explicit `pubkey` so the file path is bound to the
    /// account that initiated the fetch, not whichever account happens to be
    /// current at write-time. Without this, a fetch in flight while the user
    /// switches accounts would overwrite the new current's cached image with
    /// the old current's image — visible as "the test account's PFP suddenly
    /// disappeared / shows wrong avatar" after rapid switching.
    private func cacheImage(from urlString: String, pubkey: String) async {
        guard let url = URL(string: urlString),
              !pubkey.isEmpty else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else { return }
            // File write is unconditional on the captured pubkey — the image
            // belongs on disk for that account regardless of which account
            // is currently active. The in-memory `profileImage` update IS
            // guarded so we don't replace the visible avatar with a fetch
            // result for a different account.
            try data.write(to: cachedImageURL(for: pubkey))
            await MainActor.run {
                if self.currentAccount?.pubkeyHex == pubkey {
                    self.profileImage = image
                }
            }
        } catch {
            // Silently fail
        }
    }

    /// Fetch kind:0 profile for a SPECIFIC account pubkey. Used by both
    /// fetchProfileIfNeeded() (current account, throttled) and
    /// refreshProfile(for:) (any account, on-demand from AccountDetailView).
    private func fetchProfile(for pubkey: String) async {
        let relays = [
            "wss://relay.powr.build",
            "wss://relay.damus.io",
            "wss://nos.lol",
            "wss://relay.primal.net",
            "wss://purplepag.es"
        ]

        let results: [FetchedKind0?] = await withTaskGroup(of: FetchedKind0?.self) { group in
            for url in relays {
                group.addTask {
                    await Self.fetchProfile(from: url, pubkey: pubkey)
                }
            }
            var collected: [FetchedKind0?] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        // NIP-01: replaceable events — pick the result with the highest
        // created_at. Per-relay we already get that relay's latest (limit:1
        // returns the replaceable representative). Cross-relay we must
        // compare timestamps because relays routinely disagree on the latest
        // kind:0 (publish failures, mirror lag) and the user's primary
        // low-latency relay would otherwise win the race with a stale event
        // — surfaced as "edited profile on clave.casa, but Clave iOS still
        // shows old fields after pull-to-refresh."
        guard let winner = Self.mergeKind0(results) else { return }
        let cached = winner.profile

        // Write the cached image FIRST, then mutate accounts. The accounts
        // mutation triggers SwiftUI re-renders in any view that reads the
        // cached image file from disk (HomeView strip, SlimIdentityBar,
        // AccountDetailView banner). If we mutate accounts first, those
        // re-renders read stale bytes — the new image only lands on a
        // *subsequent* render that may never come (no further state
        // change to trigger it).
        //
        // Bug F-fixed: pass pubkey explicitly so the cache file is bound
        // to the account that triggered the fetch, not whichever account
        // happens to be current at write-time.
        if let pic = cached.pictureURL, !pic.isEmpty {
            await cacheImage(from: pic, pubkey: pubkey)
        }

        await MainActor.run {
            if self.currentAccount?.pubkeyHex == pubkey {
                // Fast path: use existing helper which also updates
                // the @Observable currentAccount property.
                self.updateCurrentProfile(cached)
            } else if let idx = self.accounts.firstIndex(where: { $0.pubkeyHex == pubkey }) {
                // Non-current account: update the accounts array in-place.
                self.accounts[idx] = Account(
                    pubkeyHex: self.accounts[idx].pubkeyHex,
                    addedAt: self.accounts[idx].addedAt,
                    profile: cached
                )
                self.persistAccounts()
            }
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

        Task { await self.fetchProfile(for: pubkey) }
    }

    /// Force a profile refresh for any account, bypassing the 1-hour cache.
    /// Called from AccountDetailView's "Refresh profile" action.
    func refreshProfile(for pubkey: String) {
        guard !pubkey.isEmpty else { return }
        Task { await self.fetchProfile(for: pubkey) }
    }

    /// Async variant of refreshProfile(for:) for SwiftUI .refreshable callers.
    /// Awaits completion so the pull-to-refresh spinner stays visible until
    /// the fetch actually finishes.
    @MainActor
    func refreshProfileAsync(for pubkey: String) async {
        guard !pubkey.isEmpty else { return }
        await fetchProfile(for: pubkey)
    }

    /// Fetch kind:0 for every account on launch, throttled per-account.
    /// Each account's `profile.fetchedAt` is checked against the 1-hour
    /// window so accounts with fresh caches are skipped. Replaces the
    /// current-account-only `fetchProfileIfNeeded()` call from HomeView
    /// onAppear so the strip's larger avatars populate for all accounts.
    func fetchProfilesForAllAccountsIfNeeded() {
        let now = Date().timeIntervalSince1970
        for account in accounts {
            if let fetched = account.profile?.fetchedAt, now - fetched < 3600 {
                continue
            }
            Task { await self.fetchProfile(for: account.pubkeyHex) }
        }
    }

    /// Force-refresh all accounts' kind:0 profiles, bypassing the 1-hour
    /// throttle. Awaits completion of every fan-out fetch so callers (e.g.
    /// HomeView's `.refreshable` pull-to-refresh) keep their spinner
    /// visible until the data lands.
    func refreshAllProfiles() async {
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                let pk = account.pubkeyHex
                group.addTask { [weak self] in
                    await self?.fetchProfile(for: pk)
                }
            }
        }
    }

    /// Cross-relay merge result for kind:0 fetches. Pairs the parsed
    /// `CachedProfile` with the source event's `created_at` so the caller
    /// can pick the latest replaceable event across relays per NIP-01.
    /// Internal (not private) so unit tests can construct fixtures via
    /// `@testable import Clave`.
    struct FetchedKind0: Equatable {
        let profile: CachedProfile
        let createdAt: Int64
    }

    /// Cross-relay selection for kind:0 fetch results. Per NIP-01,
    /// replaceable events are uniquely identified by (pubkey, kind) and the
    /// authoritative event is the one with the highest `created_at`. Returns
    /// nil if no relay returned a usable event.
    ///
    /// Pure function, extracted for unit-testability — see
    /// `AppStateProfileMergeTests`.
    static func mergeKind0(_ results: [FetchedKind0?]) -> FetchedKind0? {
        var winner: FetchedKind0?
        for result in results {
            guard let result else { continue }
            if winner == nil || result.createdAt > winner!.createdAt {
                winner = result
            }
        }
        return winner
    }

    private static func fetchProfile(from relayURL: String, pubkey: String) async -> FetchedKind0? {
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

            let displayName = json["display_name"] as? String
            let name = json["name"] as? String
            let pictureURL = json["picture"] as? String
            let about = json["about"] as? String
            let nip05 = json["nip05"] as? String
            let lud16 = json["lud16"] as? String

            // Skip empty profiles (no name AND no picture).
            // NOTE: about/nip05/lud16 are intentionally NOT included in this gate
            // for v0.2.0 — preserves pre-existing behavior. Edge case: a kind:0
            // with only bio/NIP-05/lightning data (no displayName, no name, no
            // pictureURL) returns nil and AccountDetailView's Profile section
            // shows the empty state.
            let hasIdentity = !(displayName?.isEmpty ?? true) || !(name?.isEmpty ?? true)
            let hasPicture = !(pictureURL?.isEmpty ?? true)
            if !hasIdentity && !hasPicture {
                return nil
            }

            // NSNumber bridges Int / Int64 / Double from JSONSerialization
            // (the underlying numeric type isn't deterministic across platforms).
            // Default to 0 if missing — malformed events lose the merge ranking
            // but don't crash the fetch path.
            let createdAt = (event["created_at"] as? NSNumber)?.int64Value ?? 0

            return FetchedKind0(
                profile: CachedProfile(
                    displayName: displayName,
                    name: name,
                    pictureURL: pictureURL,
                    about: about,
                    nip05: nip05,
                    lud16: lud16,
                    fetchedAt: Date().timeIntervalSince1970
                ),
                createdAt: createdAt
            )
        } catch {
            return nil
        }
    }
}
