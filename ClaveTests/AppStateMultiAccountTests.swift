import XCTest
@testable import Clave

/// AppState multi-account surface tests.
///
/// Verifies:
/// - `accounts` + `currentAccount` published state
/// - Derived `signerPubkeyHex` and `profile` from currentAccount
/// - `switchToAccount`, `addAccount`, `generateAccount`, `deleteAccount`
/// - `recoverAccountsFromKeychainIfNeeded` (reinstall recovery from
///   iOS Storage settings UserDefaults wipe)
/// - `cleanupOrphanLegacyKeychainEntry` (defensive every-launch sweep
///   for build-31-era bootstrap orphans; sunset candidate)
/// - `deleteAccount` ordering (audit finding A2)
///
/// These tests focus on local state transitions (UserDefaults +
/// Keychain). Proxy registration paths are NOT exercised — they're
/// network calls verified by manual TestFlight testing.
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

        _ = try appState.addAccount(nsec: testNsecA)
        XCTAssertEqual(appState.signerPubkeyHex, testPubkeyA)
        XCTAssertTrue(appState.isKeyImported)
    }

    func testProfile_derivedFromCurrentAccount() throws {
        _ = try appState.addAccount(nsec: testNsecA)
        XCTAssertNil(appState.profile)  // No fetch yet
    }

    // MARK: - addAccount

    func testAddAccount_appendsToList_andSetsAsCurrent() throws {
        let result = try appState.addAccount(nsec: testNsecA)
        XCTAssertEqual(result.pubkeyHex, testPubkeyA)
        XCTAssertEqual(appState.accounts.count, 1)
        XCTAssertEqual(appState.currentAccount?.pubkeyHex, testPubkeyA)
        // Keychain entry written
        XCTAssertNotNil(SharedKeychain.loadNsec(for: testPubkeyA))
    }

    func testAddAccount_duplicateNsec_switchesToExisting() throws {
        let firstAddedAt = try appState.addAccount(nsec: testNsecA).addedAt
        _ = try appState.addAccount(nsec: testNsecB)
        // currentAccount is now testPubkeyB
        XCTAssertEqual(appState.currentAccount?.pubkeyHex, testPubkeyB)

        // Re-add the first nsec — should switch back, not duplicate
        let result = try appState.addAccount(nsec: testNsecA)
        XCTAssertEqual(result.pubkeyHex, testPubkeyA)
        XCTAssertEqual(result.addedAt, firstAddedAt, "Re-add must return the existing row, not a fresh one")
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


    // MARK: - Reinstall recovery from Keychain

    func testReinstallRecovery_seedsAccountsFromKeychain() throws {
        // Setup: simulate iOS Storage settings wipe — UserDefaults
        // empty, but Keychain still has pubkey-keyed entries.
        try SharedKeychain.saveNsec(testNsecA, for: testPubkeyA)
        try SharedKeychain.saveNsec(testNsecB, for: testPubkeyB)
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.accountsKey)
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.currentSignerPubkeyHexKey)
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.signerPubkeyHexKey)
        // Also no legacy entry (so bootstrap is no-op)
        SharedKeychain.deleteNsec()

        let fresh = AppState()
        fresh.loadState()

        // Recovery reconstructs both accounts
        XCTAssertEqual(fresh.accounts.count, 2)
        let recoveredPubkeys = Set(fresh.accounts.map { $0.pubkeyHex })
        XCTAssertEqual(recoveredPubkeys, Set([testPubkeyA, testPubkeyB]))
        XCTAssertNotNil(fresh.currentAccount, "Must auto-select a current account")
        XCTAssertTrue(recoveredPubkeys.contains(fresh.currentAccount!.pubkeyHex))
    }

    func testReinstallRecovery_doesNotRunWhenAccountsKeyAlreadyPopulated() throws {
        // Setup: normal state with accountsKey already set (no recovery needed)
        _ = try appState.addAccount(nsec: testNsecA)

        // Now plant a Keychain entry that's NOT in accountsKey — recovery
        // would pick it up if it ran. Verify recovery doesn't run.
        try SharedKeychain.saveNsec(testNsecB, for: testPubkeyB)

        let fresh = AppState()
        fresh.loadState()

        // Only the original account is in the list — recovery did NOT run
        XCTAssertEqual(fresh.accounts.count, 1, "Recovery must skip when accountsKey is already populated")
        XCTAssertEqual(fresh.accounts.first?.pubkeyHex, testPubkeyA, "Original account preserved; recovery did not add testPubkeyB")
    }


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
