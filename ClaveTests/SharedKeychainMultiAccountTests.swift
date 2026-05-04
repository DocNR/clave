import XCTest
@testable import Clave

/// Task 2 of the multi-account sprint (`feat/multi-account`).
/// Verifies the new pubkey-keyed Keychain API + `listAllPubkeys()`
/// enumeration. Legacy single-account methods remain intact (used by
/// Task 8 migration); they're covered by `LightEventNip98Tests` and
/// other existing suites.
///
/// Plan: ~/hq/clave/plans/2026-04-30-multi-account-sprint.md
/// Security audit: ~/hq/clave/security-audits/2026-04-30-multi-account-pre-implementation.md
final class SharedKeychainMultiAccountTests: XCTestCase {

    // SECURITY (audit 2026-04-30 finding A4): test fixtures are GENERATED
    // at setup, never hardcoded. Avoids realistic-looking nsec strings
    // that could cause copy-paste confusion in screenshots, logs, or
    // stack traces.
    private var testPubkeyA: String!
    private var testPubkeyB: String!
    private var testNsecA: String!
    private var testNsecB: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let (nsecA, pkA) = try Self.generateTestKeyPair()
        let (nsecB, pkB) = try Self.generateTestKeyPair()
        testNsecA = nsecA
        testPubkeyA = pkA
        testNsecB = nsecB
        testPubkeyB = pkB
        // Clean any leftover items from previous runs (failed test, crash, etc.)
        SharedKeychain.deleteNsec(for: testPubkeyA)
        SharedKeychain.deleteNsec(for: testPubkeyB)
    }

    override func tearDown() {
        SharedKeychain.deleteNsec(for: testPubkeyA)
        SharedKeychain.deleteNsec(for: testPubkeyB)
        super.tearDown()
    }

    /// Generates a random 32-byte secp256k1 private key + the corresponding
    /// nsec1... bech32 + hex pubkey. Each test gets fresh keys so failures
    /// don't leak state between runs.
    private static func generateTestKeyPair() throws -> (nsec: String, pubkeyHex: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        guard status == errSecSuccess else {
            throw NSError(domain: "SharedKeychainMultiAccountTests", code: Int(status))
        }
        let privateKey = Data(bytes)
        let nsec = try Bech32.encode(hrp: "nsec", data: privateKey)
        let pubkeyHex = try LightEvent.pubkeyHex(from: privateKey)
        return (nsec, pubkeyHex)
    }

    // MARK: - Per-pubkey API

    func testSaveAndLoadByPubkey() throws {
        try SharedKeychain.saveNsec(testNsecA, for: testPubkeyA)
        XCTAssertEqual(SharedKeychain.loadNsec(for: testPubkeyA), testNsecA)
    }

    func testTwoAccountsCoexist() throws {
        try SharedKeychain.saveNsec(testNsecA, for: testPubkeyA)
        try SharedKeychain.saveNsec(testNsecB, for: testPubkeyB)
        XCTAssertEqual(SharedKeychain.loadNsec(for: testPubkeyA), testNsecA)
        XCTAssertEqual(SharedKeychain.loadNsec(for: testPubkeyB), testNsecB)
    }

    func testDeleteOneAccountLeavesOtherIntact() throws {
        try SharedKeychain.saveNsec(testNsecA, for: testPubkeyA)
        try SharedKeychain.saveNsec(testNsecB, for: testPubkeyB)
        SharedKeychain.deleteNsec(for: testPubkeyA)
        XCTAssertNil(SharedKeychain.loadNsec(for: testPubkeyA))
        XCTAssertEqual(SharedKeychain.loadNsec(for: testPubkeyB), testNsecB)
    }

    func testSaveTwiceUpdatesValue() throws {
        try SharedKeychain.saveNsec(testNsecA, for: testPubkeyA)
        try SharedKeychain.saveNsec(testNsecB, for: testPubkeyA)  // same pubkey, new value
        XCTAssertEqual(SharedKeychain.loadNsec(for: testPubkeyA), testNsecB)
    }

    func testLoadByPubkey_returnsNilWhenAbsent() {
        // No save first — loading should return nil cleanly, not throw or
        // surface a Keychain error code to the caller.
        XCTAssertNil(SharedKeychain.loadNsec(for: testPubkeyA))
    }

    // MARK: - listAllPubkeys()

    func testListAllPubkeys_returnsBothAccounts() throws {
        try SharedKeychain.saveNsec(testNsecA, for: testPubkeyA)
        try SharedKeychain.saveNsec(testNsecB, for: testPubkeyB)
        let all = SharedKeychain.listAllPubkeys()
        XCTAssertTrue(all.contains(testPubkeyA),
                      "Expected to find testPubkeyA in listAllPubkeys()")
        XCTAssertTrue(all.contains(testPubkeyB),
                      "Expected to find testPubkeyB in listAllPubkeys()")
    }

    func testListAllPubkeys_excludesLegacyAccount() throws {
        // Set up: write the legacy single-account entry (kSecAttrAccount =
        // "signer-nsec") + one pubkey-keyed entry. listAllPubkeys() should
        // surface the pubkey-keyed entry but NOT the legacy "signer-nsec"
        // string.
        try SharedKeychain.saveNsec(testNsecA)  // legacy path
        defer { SharedKeychain.deleteNsec() }   // legacy cleanup
        try SharedKeychain.saveNsec(testNsecB, for: testPubkeyB)

        let all = SharedKeychain.listAllPubkeys()
        XCTAssertFalse(all.contains(SharedConstants.keychainAccount),
                       "listAllPubkeys() must NOT surface the legacy fixed-account entry")
        XCTAssertTrue(all.contains(testPubkeyB),
                      "listAllPubkeys() should still return pubkey-keyed entries")

        // Sanity: legacy entry is detectable via the legacy API
        XCTAssertNotNil(SharedKeychain.loadNsec())
    }

    func testListAllPubkeys_emptyWhenNoEntries() {
        // setUp deleted any prior entries for testPubkeyA/B and we haven't
        // written anything. Some tests may create transient entries via
        // legacy path; this test asserts the post-cleanup behavior.
        // (Other tests in the build session may leave stray entries; we
        // only assert that OUR test pubkeys are absent, which means the
        // function doesn't return them spuriously.)
        let all = SharedKeychain.listAllPubkeys()
        XCTAssertFalse(all.contains(testPubkeyA))
        XCTAssertFalse(all.contains(testPubkeyB))
    }
}
