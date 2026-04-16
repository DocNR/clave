import Foundation

enum TrustLevel: String, Codable, CaseIterable {
    case full    // auto-sign everything
    case medium  // auto-sign everything except protected kinds
    case low     // ask for every request
}

struct ClientPermissions: Codable, Identifiable {
    var id: String { pubkey }
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

    static let defaultMethodPermissions: Set<String> = [
        "nip04_encrypt", "nip04_decrypt",
        "nip44_encrypt", "nip44_decrypt"
    ]

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
