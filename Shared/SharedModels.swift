import Foundation

struct ActivityEntry: Codable, Identifiable {
    let id: String
    let method: String
    let eventKind: Int?
    let clientPubkey: String
    let timestamp: Double
    let status: String       // "signed", "blocked", "error"
    let errorMessage: String?
}

/// A signing request for a protected kind, queued by the NSE for in-app approval.
struct PendingRequest: Codable, Identifiable {
    let id: String              // UUID
    let requestEventJSON: String // full relay event JSON (encrypted content, pubkey, etc.)
    let method: String
    let eventKind: Int?
    let clientPubkey: String
    let timestamp: Double
}

struct ConnectedClient: Codable, Identifiable {
    var id: String { pubkey }
    let pubkey: String
    var name: String?
    let firstSeen: Double
    var lastSeen: Double
    var requestCount: Int
    /// URI relays from the nostrconnect pair (empty for bunker pairings and
    /// for existing pre-V2 rows). Mirrored to the proxy's `/pair-client`
    /// payload and used to know which relays to tell the proxy about on
    /// retry.
    var relayUrls: [String] = []

    // Explicit Codable implementation so decoding existing rows without
    // `relayUrls` succeeds (Codable's default synthesis doesn't honor the
    // property default value when the key is absent in the JSON).
    private enum CodingKeys: String, CodingKey {
        case pubkey, name, firstSeen, lastSeen, requestCount, relayUrls
    }

    init(
        pubkey: String,
        name: String? = nil,
        firstSeen: Double,
        lastSeen: Double,
        requestCount: Int,
        relayUrls: [String] = []
    ) {
        self.pubkey = pubkey
        self.name = name
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.requestCount = requestCount
        self.relayUrls = relayUrls
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pubkey = try container.decode(String.self, forKey: .pubkey)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        firstSeen = try container.decode(Double.self, forKey: .firstSeen)
        lastSeen = try container.decode(Double.self, forKey: .lastSeen)
        requestCount = try container.decode(Int.self, forKey: .requestCount)
        relayUrls = try container.decodeIfPresent([String].self, forKey: .relayUrls) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pubkey, forKey: .pubkey)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(firstSeen, forKey: .firstSeen)
        try container.encode(lastSeen, forKey: .lastSeen)
        try container.encode(requestCount, forKey: .requestCount)
        try container.encode(relayUrls, forKey: .relayUrls)
    }
}

/// Queued pair/unpair operation awaiting delivery to the proxy.
/// Persisted in SharedStorage.pendingPairOps. FIFO, cap 10, drop-oldest on
/// overflow. Drained on applicationDidBecomeActive and after /register success.
struct PairOp: Codable, Identifiable {
    enum Kind: String, Codable {
        case pair
        case unpair
    }
    let id: String              // UUID
    let kind: Kind
    let clientPubkey: String
    let relayUrls: [String]?    // present for .pair, nil for .unpair
    let createdAt: Double
    var failCount: Int          // internal only — used for backoff cap
}
