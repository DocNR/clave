import Foundation

enum TrustLevel: String, Codable, CaseIterable {
    case full    // auto-sign everything
    case medium  // auto-sign everything except protected kinds
    case low     // ask for every request
}

struct ClientPermissions: Codable, Identifiable {
    /// Composite identity: `"<signer>:<client>"` so the same client paired
    /// with multiple signers produces distinct rows. Falls back to bare
    /// `pubkey` for legacy rows where `signerPubkeyHex` is empty (the brief
    /// post-decode / pre-migration window in `AppState.loadState()`); after
    /// migration backfills, every row uses the composite form.
    var id: String {
        signerPubkeyHex.isEmpty ? pubkey : "\(signerPubkeyHex):\(pubkey)"
    }
    let pubkey: String
    var trustLevel: TrustLevel
    var kindOverrides: [Int: Bool]       // per-kind overrides: true=allow, false=block
    var methodPermissions: Set<String>   // non-signing: nip04_encrypt, nip44_decrypt, etc.
    var name: String?
    var url: String?
    var imageURL: String?
    var connectedAt: Double
    var lastSeen: Double
    var requestCount: Int
    /// Pubkey of the signer (account) this client is paired with. Empty for
    /// unmigrated legacy rows; backfilled by Task 8 migration. After Task 4
    /// scoped writers land, all new rows include the signer pubkey from
    /// construction.
    let signerPubkeyHex: String

    static let defaultMethodPermissions: Set<String> = [
        "nip04_encrypt", "nip04_decrypt",
        "nip44_encrypt", "nip44_decrypt"
    ]

    init(
        pubkey: String,
        trustLevel: TrustLevel,
        kindOverrides: [Int: Bool],
        methodPermissions: Set<String>,
        name: String? = nil,
        url: String? = nil,
        imageURL: String? = nil,
        connectedAt: Double,
        lastSeen: Double,
        requestCount: Int,
        signerPubkeyHex: String = ""
    ) {
        self.pubkey = pubkey
        self.trustLevel = trustLevel
        self.kindOverrides = kindOverrides
        self.methodPermissions = methodPermissions
        self.name = name
        self.url = url
        self.imageURL = imageURL
        self.connectedAt = connectedAt
        self.lastSeen = lastSeen
        self.requestCount = requestCount
        self.signerPubkeyHex = signerPubkeyHex
    }

    // Explicit Codable — promoted from synthesized so legacy rows (no
    // `signerPubkeyHex` key) decode cleanly via `decodeIfPresent ?? ""`.
    private enum CodingKeys: String, CodingKey {
        case pubkey, trustLevel, kindOverrides, methodPermissions
        case name, url, imageURL, connectedAt, lastSeen, requestCount
        case signerPubkeyHex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pubkey = try c.decode(String.self, forKey: .pubkey)
        trustLevel = try c.decode(TrustLevel.self, forKey: .trustLevel)
        kindOverrides = try c.decode([Int: Bool].self, forKey: .kindOverrides)
        methodPermissions = try c.decode(Set<String>.self, forKey: .methodPermissions)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        imageURL = try c.decodeIfPresent(String.self, forKey: .imageURL)
        connectedAt = try c.decode(Double.self, forKey: .connectedAt)
        lastSeen = try c.decode(Double.self, forKey: .lastSeen)
        requestCount = try c.decode(Int.self, forKey: .requestCount)
        signerPubkeyHex = try c.decodeIfPresent(String.self, forKey: .signerPubkeyHex) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pubkey, forKey: .pubkey)
        try c.encode(trustLevel, forKey: .trustLevel)
        try c.encode(kindOverrides, forKey: .kindOverrides)
        try c.encode(methodPermissions, forKey: .methodPermissions)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(imageURL, forKey: .imageURL)
        try c.encode(connectedAt, forKey: .connectedAt)
        try c.encode(lastSeen, forKey: .lastSeen)
        try c.encode(requestCount, forKey: .requestCount)
        try c.encode(signerPubkeyHex, forKey: .signerPubkeyHex)
    }

    /// Check if a sign_event request for this kind is allowed
    func isKindAllowed(_ kind: Int, protectedKinds: Set<Int>) -> Bool {
        if let override = kindOverrides[kind] {
            return override
        }
        switch trustLevel {
        case .full: return true
        case .medium: return !protectedKinds.contains(kind)
        case .low: return false
        }
    }

    /// Check if a non-signing method is allowed
    func isMethodAllowed(_ method: String) -> Bool {
        methodPermissions.contains(method)
    }

    /// Compute the effective trust level label from current state
    func computedTrustLabel(protectedKinds: Set<Int>) -> String {
        if kindOverrides.isEmpty {
            return trustLevel.rawValue.capitalized
        }
        let allProtectedAllowed = protectedKinds.allSatisfy { kindOverrides[$0] == true }
        let anyNonProtectedBlocked = kindOverrides.contains { key, value in
            !protectedKinds.contains(key) && value == false
        }
        if trustLevel == .medium && allProtectedAllowed && !anyNonProtectedBlocked {
            return "Full"
        }
        if trustLevel == .full && anyNonProtectedBlocked {
            return "Custom"
        }
        return "Custom"
    }
}

enum KnownKinds {
    static let names: [Int: String] = [
        0: "Profile Metadata",
        1: "Short Note",
        3: "Contact List",
        4: "Encrypted DM (NIP-04)",
        5: "Deletion",
        6: "Repost",
        7: "Reaction",
        8: "Badge Award",
        13: "Seal (NIP-59)",
        14: "Chat Message (NIP-17)",
        1059: "Gift Wrap (NIP-59)",
        1301: "Workout Record",
        9735: "Zap Receipt",
        10002: "Relay List",
        22242: "Relay Auth (NIP-42)",
        30023: "Long-form Article",
        30078: "Application-Specific Data",
        33401: "Exercise Template",
        33402: "Workout Template",
    ]

    static func label(for kind: Int) -> String {
        if let name = names[kind] {
            return "Kind \(kind) — \(name)"
        }
        return "Kind \(kind)"
    }
}
