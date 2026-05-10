import Foundation
import OSLog

/// Async signer closure: produces the `X-Clave-Auth` header value for a
/// NIP-98-authed GET to `url`, signed by the nsec for `signerPubkey`.
///
/// `EntitlementService` deliberately doesn't touch the Keychain — the caller
/// (typically AppState) owns nsec access and provides this closure. Keeps the
/// service test-friendly (the closure is mocked) and avoids tight coupling
/// between entitlement queries and the multi-account key-load path.
typealias EntitlementSigner = @Sendable (_ signerPubkey: String, _ url: URL) async throws -> String

/// Outcome of `refresh(pubkey:)`. Surfaced for diagnostics; callers usually
/// just rely on the cache being updated as a side effect.
enum EntitlementRefreshResult: Sendable {
    case ok(Entitlement)
    case httpError(status: Int, body: String)
    case decodeError(String)
    case signerError(String)
    case transportError(String)
}

/// Thin client over `GET /entitlement?pubkey=<hex>` plus a 24h app-group cache
/// readable from both main app and the NSE.
///
/// Design notes:
///
/// - The cache uses `SharedConstants.sharedDefaults` (app-group UserDefaults)
///   keyed `entitlementCache.<pubkey>`. NSE reads via `cachedTier(for:)` —
///   no network is needed during background-launched signing.
///
/// - Network failures fall back to last-known cache (premium users on a plane
///   keep their elevated caps). Cache TTL is 24h; once stale and offline, we
///   degrade to the .free default.
///
/// - The class is intentionally not `@MainActor`. UserDefaults is documented
///   as thread-safe; URLSession is concurrent. NSE runs off the main actor.
///
/// - JSON `tier` values (`"free"`, `"premium"`) match `Tier.RawValue`
///   verbatim. JSON snake_case is mapped via explicit `CodingKeys` in
///   `Entitlement` (preferred over `.convertFromSnakeCase` for explicitness).
final class EntitlementService: @unchecked Sendable {

    // Bumped whenever the cache schema changes — invalidates stale entries.
    static let cacheVersion = 1

    static let defaultCacheTTL: TimeInterval = 24 * 60 * 60

    private let logger = Logger(subsystem: "dev.nostr.clave", category: "entitlement")
    private let proxyURL: URL
    private let session: URLSession
    private let userDefaults: UserDefaults
    private let cacheTTL: TimeInterval
    private let now: @Sendable () -> Date

    init(
        proxyURL: URL,
        session: URLSession = .shared,
        userDefaults: UserDefaults = SharedConstants.sharedDefaults,
        cacheTTL: TimeInterval = EntitlementService.defaultCacheTTL,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.proxyURL = proxyURL
        self.session = session
        self.userDefaults = userDefaults
        self.cacheTTL = cacheTTL
        self.now = now
    }

    // MARK: - reads (sync, NSE-safe)

    /// Cached effective tier for one pubkey. `nil` if no cache entry exists or
    /// the entry is expired beyond `cacheTTL`. Expired-grant downgrade is
    /// handled by `Entitlement.effectiveTier` so we don't return stale premium.
    func cachedTier(for pubkey: String) -> Tier? {
        guard let cached = loadCache(for: pubkey) else { return nil }
        let age = now().timeIntervalSince1970 - cached.cachedAt
        if age > cacheTTL { return nil }
        return cached.entitlement.effectiveTier(now: now())
    }

    /// Highest tier across the supplied pubkeys. The "billing npub" model:
    /// any one premium pubkey on the device elevates the device's effective
    /// tier. Returns `.free` if no cached entry is currently valid.
    func effectiveTier(for pubkeys: [String]) -> Tier {
        for pubkey in pubkeys {
            if cachedTier(for: pubkey) == .premium {
                return .premium
            }
        }
        return .free
    }

    // MARK: - writes (async)

    /// Refresh entitlement for every pubkey in parallel. Failures for one
    /// pubkey don't block others; the existing cache entry (if any) is kept
    /// untouched so we degrade gracefully on transient network errors.
    func refreshAll(pubkeys: [String], signer: @escaping EntitlementSigner) async {
        await withTaskGroup(of: Void.self) { group in
            for pubkey in pubkeys {
                group.addTask { [self] in
                    let result = await refresh(pubkey: pubkey, signer: signer)
                    switch result {
                    case .ok(let ent):
                        logger.info("refresh ok pubkey=\(pubkey.prefix(8)) tier=\(ent.tier.rawValue)")
                    case .httpError(let status, let body):
                        logger.warning("refresh http pubkey=\(pubkey.prefix(8)) status=\(status) body=\(body)")
                    case .decodeError(let msg):
                        logger.error("refresh decode pubkey=\(pubkey.prefix(8)) err=\(msg)")
                    case .signerError(let msg):
                        logger.warning("refresh signer pubkey=\(pubkey.prefix(8)) err=\(msg)")
                    case .transportError(let msg):
                        logger.warning("refresh transport pubkey=\(pubkey.prefix(8)) err=\(msg)")
                    }
                }
            }
        }
    }

    /// Refresh a single pubkey. Public for callers that want to refresh a
    /// just-added account immediately rather than waiting for the next
    /// `refreshAll` cycle.
    func refresh(pubkey: String, signer: @escaping EntitlementSigner) async -> EntitlementRefreshResult {
        var components = URLComponents(url: proxyURL.appendingPathComponent("entitlement"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "pubkey", value: pubkey)]
        guard let url = components?.url else {
            return .transportError("invalid_url")
        }

        let authHeader: String
        do {
            authHeader = try await signer(pubkey, url)
        } catch {
            return .signerError(String(describing: error))
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        // iOS URLSession silently strips `Authorization` — use the project's
        // X-Clave-Auth convention (see Gotcha #1 in OVERVIEW.md).
        req.setValue(authHeader, forHTTPHeaderField: "X-Clave-Auth")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            return .transportError(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            return .transportError("non-http response")
        }
        if http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
            return .httpError(status: http.statusCode, body: body)
        }

        let decoded: Entitlement
        do {
            decoded = try JSONDecoder().decode(Entitlement.self, from: data)
        } catch {
            return .decodeError(String(describing: error))
        }

        // Sanity check: server-returned pubkey must match what we asked for.
        // Defends against a misconfigured/malicious proxy returning someone
        // else's tier under our cached key.
        guard decoded.pubkey.lowercased() == pubkey.lowercased() else {
            return .decodeError("pubkey mismatch: requested=\(pubkey.prefix(8)) returned=\(decoded.pubkey.prefix(8))")
        }

        saveCache(decoded, for: pubkey)
        return .ok(decoded)
    }

    /// Drop the cached entry for one pubkey (e.g. after `deleteAccount`).
    func clearCache(for pubkey: String) {
        userDefaults.removeObject(forKey: cacheKey(for: pubkey))
    }

    /// Drop all cached entries. Dev-menu / sign-out path.
    func clearAllCache(pubkeys: [String]) {
        for pubkey in pubkeys {
            clearCache(for: pubkey)
        }
    }

    // MARK: - cache layer

    /// Wraps a stored `Entitlement` with the timestamp it was fetched at, so
    /// we can age it independently of any `expires_at` the server returned.
    /// `version` lets us invalidate stale entries if we change the schema.
    struct CachedEntitlement: Codable {
        let version: Int
        let entitlement: Entitlement
        let cachedAt: TimeInterval
    }

    func loadCache(for pubkey: String) -> CachedEntitlement? {
        guard let data = userDefaults.data(forKey: cacheKey(for: pubkey)) else { return nil }
        guard let decoded = try? JSONDecoder().decode(CachedEntitlement.self, from: data) else { return nil }
        if decoded.version != Self.cacheVersion { return nil }
        return decoded
    }

    func saveCache(_ entitlement: Entitlement, for pubkey: String) {
        let cached = CachedEntitlement(
            version: Self.cacheVersion,
            entitlement: entitlement,
            cachedAt: now().timeIntervalSince1970
        )
        guard let data = try? JSONEncoder().encode(cached) else { return }
        userDefaults.set(data, forKey: cacheKey(for: pubkey))
    }

    func cacheKey(for pubkey: String) -> String {
        "entitlementCache.\(pubkey.lowercased())"
    }
}
