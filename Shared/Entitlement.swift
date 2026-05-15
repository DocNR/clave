import Foundation

/// User's entitlement tier. Default for any pubkey without a server record.
enum Tier: String, Codable, Sendable {
    case free
    case premium
}

/// Server-side entitlement record returned by `GET /entitlement?pubkey=<hex>`.
///
/// Phase 1 only writes `expiresAt: nil` (lifetime). Phase 2 may use timestamps
/// for time-bounded grants — the `effectiveTier` accessor downgrades expired
/// premium to free transparently, so call sites don't have to special-case.
///
/// Forward-compat: the JSON decoder ignores unknown keys by default. Phase 2
/// schema additions on the proxy side won't break older iOS clients.
struct Entitlement: Codable, Sendable, Equatable {
    let pubkey: String
    let tier: Tier
    let maxAccounts: Int
    let maxClients: Int
    let grantedAt: TimeInterval?
    let expiresAt: TimeInterval?
    let grantedBy: String?

    enum CodingKeys: String, CodingKey {
        case pubkey
        case tier
        case maxAccounts = "max_accounts"
        case maxClients = "max_clients"
        case grantedAt = "granted_at"
        case expiresAt = "expires_at"
        case grantedBy = "granted_by"
    }

    init(
        pubkey: String,
        tier: Tier,
        maxAccounts: Int,
        maxClients: Int,
        grantedAt: TimeInterval? = nil,
        expiresAt: TimeInterval? = nil,
        grantedBy: String? = nil
    ) {
        self.pubkey = pubkey
        self.tier = tier
        self.maxAccounts = maxAccounts
        self.maxClients = maxClients
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.grantedBy = grantedBy
    }

    /// Effective tier accounting for expiry. Expired premium reads as free
    /// without mutating the stored record. `now` is injectable for tests.
    func effectiveTier(now: Date = Date()) -> Tier {
        guard let exp = expiresAt else { return tier }
        if exp <= now.timeIntervalSince1970 { return .free }
        return tier
    }
}
