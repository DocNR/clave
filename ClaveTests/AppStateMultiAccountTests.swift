import XCTest
@testable import Clave

/// Task 5 of the multi-account sprint (`feat/multi-account`).
///
/// Verifies the new AppState multi-account surface:
/// - `accounts` + `currentAccount` published state
/// - Derived `signerPubkeyHex` and `profile` from currentAccount
/// - `switchToAccount`, `addAccount`, `generateAccount`, `deleteAccount`,
///   `renamePetname`
/// - `bootstrapFromLegacyKeychainIfNeeded` (one-shot legacy → new format)
/// - `cleanupOrphanLegacyKeychainEntry` (defensive every-launch sweep)
/// - Petname sanitization (audit 2026-04-30 finding A3)
/// - `deleteAccount` ordering (audit finding A2)
///
/// These tests focus on local state transitions (UserDefaults +
/// Keychain). Proxy registration paths are NOT exercised — they're
/// network calls verified by manual TestFlight testing.
///
/// Plan: ~/hq/clave/plans/2026-04-30-multi-account-sprint.md
/// Security audit: ~/hq/clave/security-audits/2026-04-30-multi-account-pre-implementation.md
final class AppStateMultiAccountTests: XCTestCase {

    // SECURITY (audit A4): generated test fixtures, never hardcoded
    // realistic-looking nsec strings.
    private var testPubkeyA: String!
    private var testPubkeyB: String!
    private var testNsecA: String!
    private var testNsecB: String!
    private var appState: AppState!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let (nsecA, pkA) = try Self.generateTestKeyPair()
        let (nsecB, pkB) = try Self.generateTestKeyPair()
        testNsecA = nsecA
        testPubkeyA = pkA
        testNsecB = nsecB
        testPubkeyB = pkB
        wipeAllState()
        appState = AppState()
    }

    override func tearDown() {
        wipeAllState()
        appState = nil
        super.tearDown()
    }

    private func wipeAllState() {
        // Wipe Keychain entries
        SharedKeychain.deleteNsec(for: testPubkeyA)
        SharedKeychain.deleteNsec(for: testPubkeyB)
        SharedKeychain.deleteNsec()  // legacy fixed-account
        // Wipe UserDefaults keys
        let defaults = SharedConstants.sharedDefaults
        let keys = [
            SharedConstants.accountsKey,
            SharedConstants.currentSignerPubkeyHexKey,
            SharedConstants.signerPubkeyHexKey,
            SharedConstants.bunkerSecretsKey,
            SharedConstants.bunkerSecretKey,
            SharedConstants.activityLogKey,
            SharedConstants.pendingRequestsKey,
            SharedConstants.connectedClientsKey,
            SharedConstants.clientPermissionsKey,
            SharedConstants.pendingPairOpsKey,
            SharedConstants.cachedProfileKey,
        ]
        for k in keys { defaults.removeObject(forKey: k) }
    }

    private static func generateTestKeyPair() throws -> (nsec: String, pubkeyHex: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        guard status == errSecSuccess else {
            throw NSError(domain: "AppStateMultiAccountTests", code: Int(status))
        }
        let privateKey = Data(bytes)
        let nsec = try Bech32.encode(hrp: "nsec", data: privateKey)
        let pubkeyHex = try LightEvent.pubkeyHex(from: privateKey)
        return (nsec, pubkeyHex)
    }

    // MARK: - Derived state

    func testSignerPubkeyHex_derivedFromCurrentAccount() throws {
        XCTAssertEqual(appState.signerPubkeyHex, "")
        XCTAssertFalse(appState.isKeyImported)

        _ = try appState.addAccount(nsec: testNsecA, petname: nil)
        XCTAssertEqual(appState.signerPubkeyHex, testPubkeyA)
        XCTAssertTrue(appState.isKeyImported)
    }

    func testProfile_derivedFromCurrentAccount() throws {
        _ = try appState.addAccount(nsec: testNsecA, petname: nil)
        XCTAssertNil(appState.profile)  // No fetch yet
    }

    // MARK: - addAccount

    func testAddAccount_appendsToList_andSetsAsCurrent() throws {
        let result = try appState.addAccount(nsec: testNsecA, petname: "Work")
        XCTAssertEqual(result.pubkeyHex, testPubkeyA)
        XCTAssertEqual(result.petname, "Work")
        XCTAssertEqual(appState.accounts.count, 1)
        XCTAssertEqual(appState.currentAccount?.pubkeyHex, testPubkeyA)
        // Keychain entry written
        XCTAssertNotNil(SharedKeychain.loadNsec(for: testPubkeyA))
    }

    func testAddAccount_duplicateNsec_switchesToExisting() throws {
        _ = try appState.addAccount(nsec: testNsecA, petname: "First")
        _ = try appState.addAccount(nsec: testNsecB, petname: "Second")
        // currentAccount is now testPubkeyB
        XCTAssertEqual(appState.currentAccount?.pubkeyHex, testPubkeyB)

        // Re-add the first nsec — should switch back, not duplicate
        let result = try appState.addAccount(nsec: testNsecA, petname: "Should be ignored")
        XCTAssertEqual(result.pubkeyHex, testPubkeyA)
        XCTAssertEqual(result.petname, "First", "Existing petname must not be overwritten by re-add")
        XCTAssertEqual(appState.accounts.count, 2, "Re-add must not duplicate the row")
        XCTAssertEqual(appState.currentAccount?.pubkeyHex, testPubkeyA, "Re-add must switch to existing")
    }

    // MARK: - switchToAccount

    func testSwitchToAccount_changesCurrentAndPersists() throws {
        _ = try appState.addAccount(nsec: testNsecA)
        _ = try appState.addAccount(nsec: testNsecB)
        XCTAssertEqual(appState.currentAccount?.pubkeyHex, testPubkeyB)

        appState.switchToAccount(pubkey: testPubkeyA)
        XCTAssertEqual(appState.currentAccount?.pubkeyHex, testPubkeyA)
        XCTAssertEqual(appState.signerPubkeyHex, testPubkeyA)
        // Persisted
        XCTAssertEqual(
            SharedConstants.sharedDefaults.string(forKey: SharedConstants.currentSignerPubkeyHexKey),
            testPubkeyA
        )
    }

    func testSwitchToAccount_unknownPubkey_isNoOp() throws {
        _ = try appState.addAccount(nsec: testNsecA)
        let beforePubkey = appState.currentAccount?.pubkeyHex
        appState.switchToAccount(pubkey: "not-a-real-pubkey")
        XCTAssertEqual(appState.currentAccount?.pubkeyHex, beforePubkey)
    }

    // MARK: - deleteAccount

    func testDeleteAccount_removesKeychain_andRecords_doesNotTouchOthers() throws {
        _ = try appState.addAccount(nsec: testNsecA)
        _ = try appState.addAccount(nsec: testNsecB)
        XCTAssertEqual(appState.accounts.count, 2)

        // Add some per-account state for B that should NOT be touched
        // when we delete A.
        SharedStorage.saveClientPermissions(ClientPermissions(
            pubkey: "client-of-B",
            trustLevel: .full,
            kindOverrides: [:],
            methodPermissions: [],
            connectedAt: 0, lastSeen: 0, requestCount: 0,
            signerPubkeyHex: testPubkeyB
        ))

        appState.deleteAccount(pubkey: testPubkeyA)

        // A's Keychain entry gone; B's intact
        XCTAssertNil(SharedKeychain.loadNsec(for: testPubkeyA))
        XCTAssertNotNil(SharedKeychain.loadNsec(for: testPubkeyB))

        // A removed from accounts list; B remains
        XCTAssertEqual(appState.accounts.count, 1)
        XCTAssertEqual(appState.accounts.first?.pubkeyHex, testPubkeyB)

        // B's permission row untouched
        XCTAssertNotNil(SharedStorage.getClientPermissions(signer: testPubkeyB, client: "client-of-B"))
    }

    func testDeleteAccount_currentAccount_autoSwitchesToNext() throws {
        _ = try appState.addAccount(nsec: testNsecA)
        _ = try appState.addAccount(nsec: testNsecB)
        // currentAccount is now testPubkeyB (last added)
        XCTAssertEqual(appState.currentAccount?.pubkeyHex, testPubkeyB)

        appState.deleteAccount(pubkey: testPubkeyB)
        // Auto-switched to remaining account
        XCTAssertEqual(appState.currentAccount?.pubkeyHex, testPubkeyA)
    }

    func testDeleteAccount_lastAccount_clearsCurrent() throws {
        _ = try appState.addAccount(nsec: testNsecA)
        appState.deleteAccount(pubkey: testPubkeyA)
        XCTAssertNil(appState.currentAccount)
        XCTAssertEqual(appState.signerPubkeyHex, "")
        XCTAssertFalse(appState.isKeyImported)
        XCTAssertEqual(appState.accounts.count, 0)
    }

    // MARK: - renamePetname (audit A3 sanitization)

    func testRenamePetname_persistsAndUpdatesCurrent() throws {
        _ = try appState.addAccount(nsec: testNsecA, petname: "Old")
        appState.renamePetname(for: testPubkeyA, to: "New")
        XCTAssertEqual(appState.currentAccount?.petname, "New")
        XCTAssertEqual(appState.accounts.first?.petname, "New")
    }

    func testRenamePetname_sanitizesInput_audit_A3() throws {
        _ = try appState.addAccount(nsec: testNsecA)
        // Whitespace + newlines + super long
        let dirty = "  \n  Hello\nWorld\(String(repeating: "X", count: 200))\n  "
        appState.renamePetname(for: testPubkeyA, to: dirty)
        let result = appState.currentAccount?.petname
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.contains("\n"), "Newlines must be stripped")
        XCTAssertFalse(result!.hasPrefix(" "), "Leading whitespace must be trimmed")
        XCTAssertFalse(result!.hasSuffix(" "), "Trailing whitespace must be trimmed")
        XCTAssertLessThanOrEqual(result!.count, 64, "Length must be capped at 64 chars")
    }

    func testRenamePetname_emptyAfterSanitization_setsNilNotEmptyString() throws {
        _ = try appState.addAccount(nsec: testNsecA, petname: "Initial")
        appState.renamePetname(for: testPubkeyA, to: "   \n\n   ")
        XCTAssertNil(appState.currentAccount?.petname,
                     "All-whitespace input should clear the petname, not leave empty string")
    }

    // MARK: - Bootstrap (legacy → multi-account)

    func testBootstrap_legacyKeychainEntryPresent_seedsAccountsKey() throws {
        // Setup: legacy state — single nsec under fixed-account name + the
        // legacy signerPubkeyHexKey set. accountsKey is NOT set.
        try SharedKeychain.saveNsec(testNsecA)  // legacy fixed-account
        SharedConstants.sharedDefaults.set(testPubkeyA, forKey: SharedConstants.signerPubkeyHexKey)
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.accountsKey)
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.currentSignerPubkeyHexKey)

        // Trigger bootstrap by creating a fresh AppState + loadState.
        let fresh = AppState()
        fresh.loadState()

        // accountsKey now populated with the legacy account
        XCTAssertEqual(fresh.accounts.count, 1)
        XCTAssertEqual(fresh.accounts.first?.pubkeyHex, testPubkeyA)
        XCTAssertEqual(fresh.currentAccount?.pubkeyHex, testPubkeyA)
        // New pubkey-keyed entry exists
        XCTAssertNotNil(SharedKeychain.loadNsec(for: testPubkeyA))
        // Legacy entry is GONE
        XCTAssertNil(SharedKeychain.loadNsec(),
                     "Legacy fixed-account Keychain entry must be deleted after bootstrap")
        // currentSignerPubkeyHexKey persisted
        XCTAssertEqual(
            SharedConstants.sharedDefaults.string(forKey: SharedConstants.currentSignerPubkeyHexKey),
            testPubkeyA
        )
    }

    func testBootstrap_freshInstall_noLegacyState_isNoOp() {
        // Setup: pristine — no Keychain, no UserDefaults entries
        wipeAllState()

        let fresh = AppState()
        fresh.loadState()

        XCTAssertEqual(fresh.accounts.count, 0)
        XCTAssertNil(fresh.currentAccount)
        XCTAssertEqual(fresh.signerPubkeyHex, "")
    }

    // MARK: - Defensive cleanup of orphan legacy entry

    func testCleanupOrphanLegacyKeychainEntry_idempotent() throws {
        // Setup: simulate the rare race where bootstrap saved the new
        // entry but failed to delete legacy. accounts.count >= 1, AND
        // legacy entry exists.
        _ = try appState.addAccount(nsec: testNsecA)
        XCTAssertFalse(appState.accounts.isEmpty)
        try SharedKeychain.saveNsec(testNsecA)  // simulate the orphan
        XCTAssertNotNil(SharedKeychain.loadNsec())

        // loadState should clean it up
        appState.loadState()
        XCTAssertNil(SharedKeychain.loadNsec(),
                     "Orphan legacy entry must be cleaned by every-launch sweep")

        // Idempotent: running loadState again is a no-op
        appState.loadState()
        XCTAssertNil(SharedKeychain.loadNsec())
    }
}
