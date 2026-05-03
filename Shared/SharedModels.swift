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
    /// Pubkey of the signer this activity belongs to (Task 3 of multi-account
    /// sprint). Empty string for unmigrated legacy rows; backfilled by Task 8
    /// migration. After migration completes, every row has this populated.
    /// Filtered readers (Task 4) skip rows where this is empty.
    let signerPubkeyHex: String

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
        signedReferencedEventId: String? = nil,
        signerPubkeyHex: String = ""
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
        self.signerPubkeyHex = signerPubkeyHex
    }

    private enum CodingKeys: String, CodingKey {
        case id, method, eventKind, clientPubkey, timestamp, status, errorMessage
        case signedEventId, signedSummary, signedReferencedEventId
        case signerPubkeyHex
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
        signerPubkeyHex = try c.decodeIfPresent(String.self, forKey: .signerPubkeyHex) ?? ""
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
    /// Pubkey of the signer that should handle this request. Empty string for
    /// unmigrated legacy rows; populated for new rows enqueued by NSE / L1
    /// (Task 4 caller updates). Migration (Task 8) backfills.
    let signerPubkeyHex: String

    init(
        id: String,
        requestEventJSON: String,
        method: String,
        eventKind: Int?,
        clientPubkey: String,
        timestamp: Double,
        responseRelayUrl: String?,
        signerPubkeyHex: String = ""
    ) {
        self.id = id
        self.requestEventJSON = requestEventJSON
        self.method = method
        self.eventKind = eventKind
        self.clientPubkey = clientPubkey
        self.timestamp = timestamp
        self.responseRelayUrl = responseRelayUrl
        self.signerPubkeyHex = signerPubkeyHex
    }

    // Explicit Codable — promoted from synthesized so we can use
    // `decodeIfPresent ?? ""` for `signerPubkeyHex` on legacy rows. Wire
    // format is identical to the synthesized version for all other fields.
    private enum CodingKeys: String, CodingKey {
        case id, requestEventJSON, method, eventKind, clientPubkey, timestamp
        case responseRelayUrl, signerPubkeyHex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        requestEventJSON = try c.decode(String.self, forKey: .requestEventJSON)
        method = try c.decode(String.self, forKey: .method)
        eventKind = try c.decodeIfPresent(Int.self, forKey: .eventKind)
        clientPubkey = try c.decode(String.self, forKey: .clientPubkey)
        timestamp = try c.decode(Double.self, forKey: .timestamp)
        responseRelayUrl = try c.decodeIfPresent(String.self, forKey: .responseRelayUrl)
        signerPubkeyHex = try c.decodeIfPresent(String.self, forKey: .signerPubkeyHex) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(requestEventJSON, forKey: .requestEventJSON)
        try c.encode(method, forKey: .method)
        try c.encodeIfPresent(eventKind, forKey: .eventKind)
        try c.encode(clientPubkey, forKey: .clientPubkey)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encodeIfPresent(responseRelayUrl, forKey: .responseRelayUrl)
        try c.encode(signerPubkeyHex, forKey: .signerPubkeyHex)
    }
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
    /// Pubkey of the signer this client is paired with. Empty for unmigrated
    /// legacy rows (single-account era — no signer scoping); backfilled by
    /// Task 8 migration. Filtered readers (Task 4) use this to scope the
    /// connected-clients list to the current account.
    let signerPubkeyHex: String

    // Explicit Codable implementation so decoding existing rows without
    // `relayUrls` or `signerPubkeyHex` succeeds (Codable's default synthesis
    // doesn't honor the property default value when the key is absent in the
    // JSON).
    private enum CodingKeys: String, CodingKey {
        case pubkey, name, firstSeen, lastSeen, requestCount, relayUrls, signerPubkeyHex
    }

    init(
        pubkey: String,
        name: String? = nil,
        firstSeen: Double,
        lastSeen: Double,
        requestCount: Int,
        relayUrls: [String] = [],
        signerPubkeyHex: String = ""
    ) {
        self.pubkey = pubkey
        self.name = name
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.requestCount = requestCount
        self.relayUrls = relayUrls
        self.signerPubkeyHex = signerPubkeyHex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pubkey = try container.decode(String.self, forKey: .pubkey)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        firstSeen = try container.decode(Double.self, forKey: .firstSeen)
        lastSeen = try container.decode(Double.self, forKey: .lastSeen)
        requestCount = try container.decode(Int.self, forKey: .requestCount)
        relayUrls = try container.decodeIfPresent([String].self, forKey: .relayUrls) ?? []
        signerPubkeyHex = try container.decodeIfPresent(String.self, forKey: .signerPubkeyHex) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pubkey, forKey: .pubkey)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(firstSeen, forKey: .firstSeen)
        try container.encode(lastSeen, forKey: .lastSeen)
        try container.encode(requestCount, forKey: .requestCount)
        try container.encode(relayUrls, forKey: .relayUrls)
        try container.encode(signerPubkeyHex, forKey: .signerPubkeyHex)
    }
}

// MARK: - Multi-account models (added 2026-04-30, feat/multi-account)
//
// These types underpin the Account model in `accountsKey` UserDefaults +
// the per-account profile cache. `CachedProfile` was previously inline in
// `Clave/AppState.swift`; extracted here so multi-account code in Shared/
// can reference it. Field shapes preserved so existing UserDefaults rows
// decode without migration.

/// kind:0 profile metadata cache for an account. Refreshed by
/// `AppState.fetchProfileIfNeeded` from a small relay set (see AppState
/// for the relay list); cached for ~1h before refresh.
struct CachedProfile: Codable, Equatable {
    var displayName: String?
    var name: String?         // kind:0 short handle, distinct from displayName (long form)
    var pictureURL: String?
    var about: String?
    var nip05: String?
    var lud16: String?
    var fetchedAt: Double  // timeIntervalSince1970

    init(
        displayName: String? = nil,
        name: String? = nil,
        pictureURL: String? = nil,
        about: String? = nil,
        nip05: String? = nil,
        lud16: String? = nil,
        fetchedAt: Double
    ) {
        self.displayName = displayName
        self.name = name
        self.pictureURL = pictureURL
        self.about = about
        self.nip05 = nip05
        self.lud16 = lud16
        self.fetchedAt = fetchedAt
    }
}

/// One Nostr identity owned by this device. Persisted as part of
/// `[Account]` under `SharedConstants.accountsKey`. Pubkey is the foreign
/// key for every per-account record (Keychain entry, ClientPermissions,
/// activity log, pending requests, bunker secret, etc.).
///
/// Display name resolves: `petname ?? profile?.displayName ??
/// truncatedNpub`. Avatar resolves: cached profile picture → AvatarView's
/// initials+gradient generated from `pubkeyHex` + display name.
struct Account: Codable, Identifiable, Equatable {
    var id: String { pubkeyHex }

    /// Hex-encoded 32-byte secp256k1 public key. Stable across petname
    /// renames + profile refreshes; used as the kSecAttrAccount for the
    /// account's Keychain entry, and as the foreign key on every
    /// per-account SharedStorage record.
    let pubkeyHex: String

    /// User-supplied label, optional. Preferred display name when set.
    /// Sanitized at write time (trimmed, newlines stripped, capped at 64
    /// chars) — see `AppState.renamePetname` (Task 5).
    var petname: String?

    /// `Date.timeIntervalSince1970` of when this account was added on
    /// this device. Used for "Added on …" rows in account detail views.
    var addedAt: Double

    /// Most-recently-fetched kind:0 metadata for this pubkey. nil when
    /// the relay fetch hasn't completed yet (e.g., right after import or
    /// after reinstall recovery). Refreshed by AppState on a per-account
    /// schedule.
    var profile: CachedProfile?

    init(
        pubkeyHex: String,
        petname: String? = nil,
        addedAt: Double,
        profile: CachedProfile? = nil
    ) {
        self.pubkeyHex = pubkeyHex
        self.petname = petname
        self.addedAt = addedAt
        self.profile = profile
    }
}

extension Account {
    /// Display label preference: petname → kind:0 displayName → 8-char pubkey prefix.
    /// Centralizes the resolution chain previously duplicated across view files.
    var displayLabel: String {
        if let p = petname, !p.isEmpty { return p }
        if let d = profile?.displayName, !d.isEmpty { return d }
        return String(pubkeyHex.prefix(8))
    }

    /// Hard cap on simultaneous accounts per device. HomeView strip-add pill
    /// + SettingsView Add Account row pre-check; AppState.addAccount enforces
    /// as a safety net. Headroom for additional accounts will arrive later.
    static let maxAccountsPerDevice: Int = 4

    /// Hard cap on paired NIP-46 clients per account. HomeView Pair New
    /// Connection row pre-checks; ApprovalSheet + LightSigner enforce as
    /// safety nets when a connection request lands without going through
    /// the UI tap path. Per-account, not global — each account maintains
    /// its own pairing roster.
    static let maxClientsPerAccount: Int = 5
}

/// Errors specific to multi-account management surfaced to the UI layer.
enum AccountError: LocalizedError {
    case accountCapReached
    case connectionCapReached

    var errorDescription: String? {
        switch self {
        case .accountCapReached:
            return "You can have up to \(Account.maxAccountsPerDevice) accounts on this device. More accounts will be available in the future."
        case .connectionCapReached:
            return "You can pair up to \(Account.maxClientsPerAccount) clients per account. Unpair one in Settings → Clients to continue. More connections will be available in the future."
        }
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
    /// Pubkey of the signer this pair operation belongs to. Empty for
    /// unmigrated legacy rows; populated for new rows enqueued by AppState
    /// (Task 5 caller updates). Drain logic uses this to load the right
    /// nsec for NIP-98 signing per op.
    let signerPubkeyHex: String

    init(
        id: String,
        kind: Kind,
        clientPubkey: String,
        relayUrls: [String]?,
        createdAt: Double,
        failCount: Int,
        signerPubkeyHex: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.clientPubkey = clientPubkey
        self.relayUrls = relayUrls
        self.createdAt = createdAt
        self.failCount = failCount
        self.signerPubkeyHex = signerPubkeyHex
    }

    // Explicit Codable — promoted from synthesized so legacy rows decode
    // cleanly via `decodeIfPresent ?? ""`.
    private enum CodingKeys: String, CodingKey {
        case id, kind, clientPubkey, relayUrls, createdAt, failCount, signerPubkeyHex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        clientPubkey = try c.decode(String.self, forKey: .clientPubkey)
        relayUrls = try c.decodeIfPresent([String].self, forKey: .relayUrls)
        createdAt = try c.decode(Double.self, forKey: .createdAt)
        failCount = try c.decode(Int.self, forKey: .failCount)
        signerPubkeyHex = try c.decodeIfPresent(String.self, forKey: .signerPubkeyHex) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(clientPubkey, forKey: .clientPubkey)
        try c.encodeIfPresent(relayUrls, forKey: .relayUrls)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(failCount, forKey: .failCount)
        try c.encode(signerPubkeyHex, forKey: .signerPubkeyHex)
    }
}
