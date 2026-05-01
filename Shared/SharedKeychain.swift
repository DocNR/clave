import Foundation
import Security

enum SharedKeychain {

    static func saveNsec(_ nsec: String) throws {
        guard let data = nsec.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConstants.keychainService,
            kSecAttrAccount as String: SharedConstants.keychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConstants.keychainService,
            kSecAttrAccount as String: SharedConstants.keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.writeFailed(status)
        }
    }

    static func loadNsec() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConstants.keychainService,
            kSecAttrAccount as String: SharedConstants.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let nsec = String(data: data, encoding: .utf8) else {
            return nil
        }
        return nsec
    }

    static func deleteNsec() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConstants.keychainService,
            kSecAttrAccount as String: SharedConstants.keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Multi-account (per-pubkey) API
    //
    // Added 2026-04-30 (feat/multi-account, Task 2). One Keychain entry per
    // account, keyed by `kSecAttrAccount = pubkeyHex`. `kSecAttrService` and
    // `kSecAttrAccessible` unchanged from the legacy single-account path.
    //
    // The legacy single-account methods above (saveNsec(_:), loadNsec(),
    // deleteNsec()) remain — Task 8 migration reads the legacy entry once,
    // copies it to a pubkey-keyed entry, then deletes the legacy entry.
    //
    // SECURITY (audit 2026-04-30 finding A1): enumeration of pubkey-keyed
    // entries lives in a separate file (Shared/SharedKeychain+Enumeration.swift)
    // included only in the main app target. NSE target should not be able to
    // call listAllPubkeys() — only loadNsec(for:) with the pubkey from the
    // APNs payload.

    /// Save an nsec under the given pubkey hex as the kSecAttrAccount.
    /// Replaces any existing entry for the same pubkey.
    static func saveNsec(_ nsec: String, for pubkeyHex: String) throws {
        guard let data = nsec.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConstants.keychainService,
            kSecAttrAccount as String: pubkeyHex
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConstants.keychainService,
            kSecAttrAccount as String: pubkeyHex,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.writeFailed(status)
        }
    }

    /// Load nsec by pubkey. Returns nil if no entry for that pubkey.
    static func loadNsec(for pubkeyHex: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConstants.keychainService,
            kSecAttrAccount as String: pubkeyHex,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let nsec = String(data: data, encoding: .utf8) else {
            return nil
        }
        return nsec
    }

    /// Delete the entry for a specific pubkey. No-op if absent.
    static func deleteNsec(for pubkeyHex: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConstants.keychainService,
            kSecAttrAccount as String: pubkeyHex
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainError: LocalizedError {
    case encodingFailed
    case writeFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Failed to encode key data"
        case .writeFailed(let s): return "Keychain write failed: \(s)"
        }
    }
}
