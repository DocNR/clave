import Foundation

enum TrustLevel: String, Codable, CaseIterable {
    case full    // auto-sign everything
    case medium  // auto-sign everything except protected kinds
    case low     // ask for every request
}

/// Composite key for NIP-44 v3 "always allow" grants.
///
/// v3 RPCs carry caller-supplied `kind + scope` parameters that are bound
/// into the MAC. Permissions therefore live at `(method, kind, scope?)`
/// granularity rather than the v2 method-level granularity.
///
/// `scope == nil` means "wildcard scope under this kind" — the user
/// granted "always allow kind N (any scope)" rather than a specific
/// `(kind, scope)` pair. `scope` is otherwise stored as the raw UTF-8
/// string the caller supplied (no canonicalization, per spec
/// `implementing.md`).
///
/// Hashable so it fits in `Set<KindScopeKey>`; Codable for persistence.
struct KindScopeKey: Codable, Hashable, Sendable {
    let kind: UInt32
    let scope: String?
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
    /// Per-(method, kind, scope) grants for NIP-44 v3 methods.
    ///
    /// Map shape: `method_name → Set<KindScopeKey>`. Methods covered today
    /// are `"nip44v3_encrypt"` and `"nip44v3_decrypt"`. Absence of a method
    /// key means "ask for every call." Presence of `KindScopeKey(kind, nil)`
    /// means "wildcard scope for this kind" (user granted "always allow kind N").
    ///
    /// Distinct from `methodPermissions` (v2 path) so v2 grants don't
    /// implicitly cover v3 — matches Amber's resolved design from PR #448
    /// review (`extensions/nip46.md` adopters keep the two paths separate).
    /// Forced wipe on schema-version upgrade handles the migration cleanly
    /// without per-row schema versioning (BACKLOG NIP-44 v3 "permission
    /// migration RESOLVED 2026-06-02").
    var v3KindScopePermissions: [String: Set<KindScopeKey>] = [:]

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
        signerPubkeyHex: String = "",
        v3KindScopePermissions: [String: Set<KindScopeKey>] = [:]
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
        self.v3KindScopePermissions = v3KindScopePermissions
    }

    // Explicit Codable — promoted from synthesized so legacy rows (no
    // `signerPubkeyHex` key) decode cleanly via `decodeIfPresent ?? ""`.
    private enum CodingKeys: String, CodingKey {
        case pubkey, trustLevel, kindOverrides, methodPermissions
        case name, url, imageURL, connectedAt, lastSeen, requestCount
        case signerPubkeyHex
        case v3KindScopePermissions
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
        v3KindScopePermissions = try c.decodeIfPresent([String: Set<KindScopeKey>].self, forKey: .v3KindScopePermissions) ?? [:]
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
        if !v3KindScopePermissions.isEmpty {
            try c.encode(v3KindScopePermissions, forKey: .v3KindScopePermissions)
        }
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

    /// Check if a NIP-44 v3 RPC call is auto-approvable based on stored
    /// `(method, kind, scope)` grants.
    ///
    /// Lookup order:
    ///   1. Exact `(method, kind, scope)` match — user granted this exact
    ///      combination.
    ///   2. Wildcard-scope match `(method, kind, nil)` — user granted "any
    ///      scope for this kind."
    ///   3. Otherwise: not auto-approvable — surface to user via the
    ///      approval UI.
    ///
    /// Does NOT consult `methodPermissions` (the v2 method-level grant).
    /// v2 grants don't implicitly cover v3 — separate intent, separate
    /// security model (kind/scope binding into MAC).
    ///
    /// - Parameters:
    ///   - method: RPC method name, e.g. `"nip44v3_decrypt"`.
    ///   - kind: Caller-supplied kind parameter from the v3 RPC.
    ///   - scope: Caller-supplied scope parameter from the v3 RPC. Pass an
    ///     empty string for kinds with no scope.
    /// - Returns: `true` if a matching grant exists, otherwise `false`.
    func isV3CallAllowed(method: String, kind: UInt32, scope: String) -> Bool {
        guard let grants = v3KindScopePermissions[method] else { return false }
        if grants.contains(KindScopeKey(kind: kind, scope: scope)) { return true }
        if grants.contains(KindScopeKey(kind: kind, scope: nil)) { return true }
        return false
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

    /// Return a copy of these permissions with `signerPubkeyHex` rewritten.
    /// Used by the multi-account nostrconnect handshake loop to produce N
    /// distinct rows from a single template — one per `(signer_i, client)`
    /// composite key, all carrying the same trust/kind/method values
    /// (spec §"handleNostrConnect — N-up handshake loop").
    ///
    /// Pure function so it can be unit-tested without touching SharedStorage
    /// or the live network handshake. `signerPubkeyHex` is declared `let`
    /// to enforce row-scope immutability everywhere else; this is the one
    /// well-defined point at which a template is cloned for a new signer.
    func with(signerPubkeyHex newSignerPubkeyHex: String) -> ClientPermissions {
        ClientPermissions(
            pubkey: pubkey,
            trustLevel: trustLevel,
            kindOverrides: kindOverrides,
            methodPermissions: methodPermissions,
            name: name,
            url: url,
            imageURL: imageURL,
            connectedAt: connectedAt,
            lastSeen: lastSeen,
            requestCount: requestCount,
            signerPubkeyHex: newSignerPubkeyHex,
            v3KindScopePermissions: v3KindScopePermissions
        )
    }
}

/// Sensitivity classification for NIP-44 v3 approval prompts.
///
/// Determines:
///   - Whether a warning banner shows above the standard prompt.
///   - Whether the "always allow" grant option is available.
///   - How prominently the kind label is presented.
///
/// Tier verification: spec lookup pass on 2026-06-02 (recon report
/// `~/hq/clave/research/nip44v3-impl-recon-2026-06-02.md` + report
/// Decision #2 RESOLVED). NIP-57 zaps and NIP-61 nutzaps are unencrypted
/// today and don't appear here; if NIP-57's "Future Work" private-zap
/// extension ships, kind 9734 becomes `.tierA`.
enum SensitivityTier: String, Codable {
    /// Plain prompt, all grant options available.
    case normal
    /// Range-based heuristic (NIP-51 private list/set content). Warning
    /// banner + all grant options available.
    case tierB
    /// Sensitive (warning banner; session/always grants available with
    /// emphasis on the kind). Covers DMs, seals, gift wraps, Cashu
    /// non-balance data.
    case tierA
    /// Strictest — no "always allow" available, only "once" or "deny."
    /// Reserved for direct financial-loss kinds (Cashu wallet privkey +
    /// spendable token balance).
    case tierS
}

enum KnownKinds {
    static let names: [Int: String] = [
        // Profile + microblogging
        0: "Profile Metadata",
        1: "Short Note",
        3: "Contact List",
        // DMs + gift wraps (NIP-04, NIP-17, NIP-59) — all Tier A
        4: "Encrypted DM (NIP-04)",
        5: "Deletion",
        6: "Repost",
        7: "Reaction",
        8: "Badge Award",
        13: "Seal (NIP-59)",
        14: "Sealed Direct Message (NIP-17)",
        15: "Sealed File Message (NIP-17)",
        1059: "Gift Wrap (NIP-59)",
        // Cashu wallet (NIP-60) — Tier S for 17375/7375, Tier A for 7374/7376
        7374: "Cashu Mint Quote (NIP-60)",
        7375: "Cashu Token (NIP-60)",
        7376: "Cashu Spending History (NIP-60)",
        17375: "Cashu Wallet (NIP-60)",
        // Misc
        1301: "Workout Record",
        9735: "Zap Receipt",
        10002: "Relay List",
        22242: "Relay Auth (NIP-42)",
        30023: "Long-form Article",
        30078: "Application-Specific Data",
        33401: "Exercise Template",
        33402: "Workout Template",
    ]

    /// Tier S — direct financial-loss kinds. No "always allow" available
    /// in the approval UI; only "once" or "deny". A leak here = lose
    /// money (Cashu wallet privkey = lose receive capability; Cashu
    /// token = lose spendable balance).
    static let sensitiveTierS: Set<Int> = [17375, 7375]

    /// Tier A — sensitive (warning banner, session/always grants OK).
    /// Covers DM content (4, 13, 14, 15, 1059) and Cashu financial
    /// privacy / quote info (7374, 7376).
    static let sensitiveTierA: Set<Int> = [4, 13, 14, 15, 1059, 7374, 7376]

    static func label(for kind: Int) -> String {
        if let name = names[kind] {
            return "Kind \(kind) — \(name)"
        }
        return "Kind \(kind)"
    }

    /// Classifies a kind for v3 approval-UI rendering. Spec-validated via
    /// the lookup pass against NIP-17, NIP-51, NIP-59, NIP-60, NIP-61.
    ///
    /// Resolution order:
    ///   1. Tier S explicit set (financial root capability).
    ///   2. Tier A explicit set (DM content, gift wraps, Cashu non-money).
    ///   3. Range-based Tier B heuristic for NIP-51 lists (`10000-10999`)
    ///      and sets (`30000-39999`). Future-proof against new list kinds.
    ///   4. Default `.normal`.
    static func sensitivityTier(for kind: Int) -> SensitivityTier {
        if sensitiveTierS.contains(kind) { return .tierS }
        if sensitiveTierA.contains(kind) { return .tierA }
        if (10000...10999).contains(kind) || (30000...39999).contains(kind) {
            return .tierB
        }
        return .normal
    }
}
