import Foundation
import Security

// SECURITY (audit 2026-04-30 finding A1):
//
// This file is included ONLY in the main app target — NOT the ClaveNSE target.
// Verify via Xcode "Target Membership" panel after adding the file: the
// "ClaveNSE" checkbox MUST be unchecked. Verification command:
//
//     grep -c listAllPubkeys ClaveNSE/   # must return 0
//
// Reason: NSE compromise should not enable enumeration → exfiltration of all
// accounts' nsecs from a single push wake. The NSE only ever needs
// `loadNsec(for: pubkeyFromAPNsPayload)` — never enumeration. Keeping this
// function out of the NSE binary is compile-time enforcement of that
// constraint.
//
// Pubkey enumeration is a main-app-only operation: used by reinstall recovery
// (Task 8) and the future account picker UI (Stage C). Both run only in the
// foreground main app process.

extension SharedKeychain {

    /// Enumerate all pubkey-keyed entries (excludes the legacy single-account
    /// entry). Returns the `kSecAttrAccount` strings without ever reading
    /// `kSecValueData` — this query is metadata-only by construction.
    ///
    /// Used by:
    /// - `recoverAccountsFromKeychainIfNeeded` (Task 8) — seeds `accountsKey`
    ///   on app reinstall when UserDefaults is wiped but Keychain persists.
    /// - Account picker UI (Stage C, future) — surfaces accounts whose
    ///   metadata is missing from `accountsKey` for any reason.
    ///
    /// **Main-app target only.** See file-level SECURITY comment.
    static func listAllPubkeys() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConstants.keychainService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String else { return nil }
            // Exclude the legacy fixed-string account ("signer-nsec") — it's
            // not a pubkey. Only Task 8 migration's legacy fallback path
            // uses the no-arg `loadNsec()` to read it directly.
            return account == SharedConstants.keychainAccount ? nil : account
        }
    }
}
