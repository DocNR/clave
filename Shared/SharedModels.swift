import Foundation

struct ActivityEntry: Codable, Identifiable {
    let id: String
    let method: String
    let eventKind: Int?
    let clientPubkey: String
    let timestamp: Double
    let status: String       // "signed", "blocked", "error"
    let errorMessage: String?
    /// Hex id of the resulting signed event. Set only for `sign_event` with
    /// status `"signed"`. Powers the njump deep link + Copy ID button in
    /// ActivityDetailView. nil for everything else.
    let signedEventId: String?
    /// One-line characterization of what was signed, built at log-time from
    /// kind + tags via `ActivitySummary.signedSummary`. Stored verbatim
    /// (≤120 chars). Pet-name substitution for `@<pubkey>` happens at render
    /// time so renames apply retroactively.
    let signedSummary: String?
    /// First `e` tag for kinds where the signed event is a wrapper around a
    /// reference (kind:6 repost, kind:7 reaction, kind:9734 zap request,
    /// kind:9735 zap receipt). The activity detail view's "Open on njump.me"
    /// button uses this id instead of `signedEventId` for those kinds —
    /// linking to a "❤" reaction itself is useless; linking to the
    /// reacted-to note is what the user actually wants. nil for everything
    /// else; `signedEventId` always carries the user's actual signed event
    /// for the Copy button.
    let signedReferencedEventId: String?

    init(
        id: String,
        method: String,
        eventKind: Int?,
        clientPubkey: String,
        timestamp: Double,
        status: String,
        errorMessage: String?,
        signedEventId: String? = nil,
        signedSummary: String? = nil,
        signedReferencedEventId: String? = nil
    ) {
        self.id = id
        self.method = method
        self.eventKind = eventKind
        self.clientPubkey = clientPubkey
        self.timestamp = timestamp
        self.status = status
        self.errorMessage = errorMessage
        self.signedEventId = signedEventId
        self.signedSummary = signedSummary
        self.signedReferencedEventId = signedReferencedEventId
    }

    private enum CodingKeys: String, CodingKey {
        case id, method, eventKind, clientPubkey, timestamp, status, errorMessage
        case signedEventId, signedSummary, signedReferencedEventId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        method = try c.decode(String.self, forKey: .method)
        eventKind = try c.decodeIfPresent(Int.self, forKey: .eventKind)
        clientPubkey = try c.decode(String.self, forKey: .clientPubkey)
        timestamp = try c.decode(Double.self, forKey: .timestamp)
        status = try c.decode(String.self, forKey: .status)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        signedEventId = try c.decodeIfPresent(String.self, forKey: .signedEventId)
        signedSummary = try c.decodeIfPresent(String.self, forKey: .signedSummary)
        signedReferencedEventId = try c.decodeIfPresent(String.self, forKey: .signedReferencedEventId)
    }
}

/// A signing request for a protected kind, queued by the NSE for in-app approval.
struct PendingRequest: Codable, Identifiable {
    let id: String              // UUID
    let requestEventJSON: String // full relay event JSON (encrypted content, pubkey, etc.)
    let method: String
    let eventKind: Int?
    let clientPubkey: String
    let timestamp: Double
    /// Relay URL the request was received on. Threaded back into
    /// LightSigner.handleRequest at approval-time so the response publishes
    /// to the same relay the client is actually subscribed on — not the
    /// powr.build fallback.
    ///
    /// Optional for backward compatibility — Codable decodes missing keys on
    /// Optional properties as nil without throwing, so pre-build-22 rows in
    /// UserDefaults decode cleanly and fall back to SharedConstants.relayURL
    /// at publish time.
    let responseRelayUrl: String?
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
