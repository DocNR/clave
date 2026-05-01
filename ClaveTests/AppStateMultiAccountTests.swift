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

    // MARK: - Bootstrap backfill of legacy records (Task 7 dependency)

    func testBootstrap_backfillsSignerPubkeyHexOnLegacyRecords() throws {
        // Setup: legacy state — single nsec under fixed-account name, the
        // legacy signerPubkeyHexKey set, AND existing records with empty
        // signerPubkeyHex (Task 3 default for missing wire-format key).
        try SharedKeychain.saveNsec(testNsecA)  // legacy
        SharedConstants.sharedDefaults.set(testPubkeyA, forKey: SharedConstants.signerPubkeyHexKey)
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.accountsKey)

        // Pre-bootstrap: stash records with empty signer (build-31 shape)
        SharedStorage.logActivity(ActivityEntry(
            id: "legacy-1", method: "sign_event", eventKind: 1,
            clientPubkey: "client-1", timestamp: 1, status: "signed",
            errorMessage: nil
            // signerPubkeyHex defaulted to ""
        ))
        SharedStorage.queuePendingRequest(PendingRequest(
            id: "legacy-pending-1", requestEventJSON: "{}", method: "sign_event",
            eventKind: 1, clientPubkey: "client-1", timestamp: 1,
            responseRelayUrl: nil
        ))
        SharedStorage.saveClientPermissions(ClientPermissions(
            pubkey: "client-1", trustLevel: .full,
            kindOverrides: [:], methodPermissions: [],
            connectedAt: 0, lastSeen: 0, requestCount: 0
        ))

        // Pre-bootstrap sanity: no signer stamped
        XCTAssertEqual(SharedStorage.getActivityLog().first?.signerPubkeyHex, "")
        XCTAssertEqual(SharedStorage.getPendingRequests().first?.signerPubkeyHex, "")
        XCTAssertEqual(SharedStorage.getClientPermissions().first?.signerPubkeyHex, "")

        // Trigger bootstrap
        let fresh = AppState()
        fresh.loadState()

        // Post-bootstrap: every legacy record has signerPubkeyHex stamped
        XCTAssertEqual(SharedStorage.getActivityLog().first?.signerPubkeyHex, testPubkeyA,
                       "ActivityEntry must be backfilled with the bootstrapped pubkey")
        XCTAssertEqual(SharedStorage.getPendingRequests().first?.signerPubkeyHex, testPubkeyA,
                       "PendingRequest must be backfilled")
        XCTAssertEqual(SharedStorage.getClientPermissions().first?.signerPubkeyHex, testPubkeyA,
                       "ClientPermissions must be backfilled")

        // Filtered readers (Task 4) now find the records — Task 7 view
        // reads will work post-bootstrap.
        XCTAssertEqual(SharedStorage.getActivityLog(for: testPubkeyA).count, 1)
        XCTAssertEqual(SharedStorage.getPendingRequests(for: testPubkeyA).count, 1)
        XCTAssertEqual(SharedStorage.getClientPermissions(forSigner: testPubkeyA).count, 1)
    }

    // MARK: - Task 8: extended bootstrap + recovery + cross-version cleanup

    func testBootstrap_migratesLegacyCachedProfile_intoAccountProfile() throws {
        // Setup: legacy state + cached profile in UserDefaults
        try SharedKeychain.saveNsec(testNsecA)
        SharedConstants.sharedDefaults.set(testPubkeyA, forKey: SharedConstants.signerPubkeyHexKey)
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.accountsKey)

        let legacy = CachedProfile(displayName: "Old Name", pictureURL: "https://example.com/p.jpg", fetchedAt: 1000)
        let data = try JSONEncoder().encode(legacy)
        SharedConstants.sharedDefaults.set(data, forKey: SharedConstants.cachedProfileKey)

        let fresh = AppState()
        fresh.loadState()

        XCTAssertEqual(fresh.currentAccount?.profile?.displayName, "Old Name",
                       "Bootstrap must migrate cachedProfileKey into Account.profile")
        XCTAssertNil(SharedConstants.sharedDefaults.data(forKey: SharedConstants.cachedProfileKey),
                     "Legacy cachedProfileKey must be cleared after migration")
    }

    func testBootstrap_migratesLegacyBunkerSecret_intoPerSignerDict() throws {
        try SharedKeychain.saveNsec(testNsecA)
        SharedConstants.sharedDefaults.set(testPubkeyA, forKey: SharedConstants.signerPubkeyHexKey)
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.accountsKey)
        SharedConstants.sharedDefaults.set("legacysecret123", forKey: SharedConstants.bunkerSecretKey)

        let fresh = AppState()
        fresh.loadState()

        XCTAssertEqual(SharedStorage.getBunkerSecret(for: testPubkeyA), "legacysecret123",
                       "Per-signer dict must inherit the legacy bunker secret")
        XCTAssertNil(SharedConstants.sharedDefaults.string(forKey: SharedConstants.bunkerSecretKey),
                     "Legacy bunkerSecretKey must be cleared after migration")
    }

    func testBootstrap_migratesLegacyLastContactSet_intoPerSignerDict() throws {
        try SharedKeychain.saveNsec(testNsecA)
        SharedConstants.sharedDefaults.set(testPubkeyA, forKey: SharedConstants.signerPubkeyHexKey)
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.accountsKey)

        let legacyContacts = ["pub1", "pub2", "pub3"]
        let data = try JSONEncoder().encode(legacyContacts)
        SharedConstants.sharedDefaults.set(data, forKey: SharedConstants.lastContactSetKey)

        let fresh = AppState()
        fresh.loadState()

        XCTAssertEqual(SharedStorage.getLastContactSet(for: testPubkeyA), Set(legacyContacts),
                       "Per-signer dict must inherit the legacy contact set")
        XCTAssertNil(SharedConstants.sharedDefaults.data(forKey: SharedConstants.lastContactSetKey),
                     "Legacy lastContactSetKey must be cleared after migration")
    }

    func testBootstrap_migratesLegacyRegisterTimestamps() throws {
        try SharedKeychain.saveNsec(testNsecA)
        SharedConstants.sharedDefaults.set(testPubkeyA, forKey: SharedConstants.signerPubkeyHexKey)
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.accountsKey)
        SharedConstants.sharedDefaults.set(1234567890.0, forKey: SharedConstants.lastRegisterSucceededAtKey)
        SharedConstants.sharedDefaults.set(1234567000.0, forKey: SharedConstants.lastRegisterFailedAtKey)

        let fresh = AppState()
        fresh.loadState()

        XCTAssertEqual(SharedStorage.getLastRegisterSucceededAt(for: testPubkeyA), 1234567890.0)
        XCTAssertEqual(SharedStorage.getLastRegisterFailedAt(for: testPubkeyA), 1234567000.0)
        XCTAssertEqual(SharedConstants.sharedDefaults.double(forKey: SharedConstants.lastRegisterSucceededAtKey), 0.0)
        XCTAssertEqual(SharedConstants.sharedDefaults.double(forKey: SharedConstants.lastRegisterFailedAtKey), 0.0)
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
        _ = try appState.addAccount(nsec: testNsecA, petname: "Existing")

        // Now plant a Keychain entry that's NOT in accountsKey — recovery
        // would pick it up if it ran. Verify recovery doesn't run.
        try SharedKeychain.saveNsec(testNsecB, for: testPubkeyB)

        let fresh = AppState()
        fresh.loadState()

        // Only the original account is in the list — recovery did NOT run
        XCTAssertEqual(fresh.accounts.count, 1, "Recovery must skip when accountsKey is already populated")
        XCTAssertEqual(fresh.accounts.first?.petname, "Existing")
    }

    // MARK: - Cross-version cleanup (Task 5 shipped without Task 8)

    func testMigrateRemainingLegacyKeys_idempotentlyCleansUpAfterPriorBootstrap() throws {
        // Simulate user who upgraded to Task 5 (which only did partial
        // migration) and now upgrades to Task 8. Their accountsKey is
        // populated but legacy keys still linger.
        _ = try appState.addAccount(nsec: testNsecA, petname: nil)

        // Plant legacy keys as if Task 5 had not migrated them
        SharedConstants.sharedDefaults.set("oldsecret", forKey: SharedConstants.bunkerSecretKey)
        let oldContacts = try JSONEncoder().encode(["x", "y"])
        SharedConstants.sharedDefaults.set(oldContacts, forKey: SharedConstants.lastContactSetKey)
        SharedConstants.sharedDefaults.set(99999.0, forKey: SharedConstants.lastRegisterSucceededAtKey)

        // Reload — migrateRemainingLegacyKeysIfNeeded should clean them up
        let fresh = AppState()
        fresh.loadState()

        XCTAssertNil(SharedConstants.sharedDefaults.string(forKey: SharedConstants.bunkerSecretKey),
                     "Cross-version cleanup must remove legacy bunkerSecretKey")
        XCTAssertNil(SharedConstants.sharedDefaults.data(forKey: SharedConstants.lastContactSetKey),
                     "Cross-version cleanup must remove legacy lastContactSetKey")
        XCTAssertEqual(SharedConstants.sharedDefaults.double(forKey: SharedConstants.lastRegisterSucceededAtKey), 0.0,
                       "Cross-version cleanup must remove legacy lastRegisterSucceededAtKey")

        // Verify the values were correctly migrated, not lost
        XCTAssertEqual(SharedStorage.getBunkerSecret(for: testPubkeyA), "oldsecret")
        XCTAssertEqual(SharedStorage.getLastContactSet(for: testPubkeyA), Set(["x", "y"]))
        XCTAssertEqual(SharedStorage.getLastRegisterSucceededAt(for: testPubkeyA), 99999.0)
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
