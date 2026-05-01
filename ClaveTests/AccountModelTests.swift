import XCTest
@testable import Clave

/// Task 1 of the multi-account sprint (`feat/multi-account`).
/// Verifies the new `Account` + `CachedProfile` model + the new
/// SharedConstants keys. Pure additive; no behavior change yet.
/// Plan: ~/hq/clave/plans/2026-04-30-multi-account-sprint.md
final class AccountModelTests: XCTestCase {

    // MARK: - Account Codable

    func testAccount_codableRoundtrip_preservesAllFields() throws {
        let original = Account(
            pubkeyHex: "55127fc9e1c03c6b459a3bab72fdb99def1644c5f239bdd09f3e5fb401ed9b21",
            petname: "POWR Test",
            addedAt: 1714500000.0,
            profile: CachedProfile(
                displayName: "TestUser",
                pictureURL: "https://example.com/pic.jpg",
                fetchedAt: 1714500000.0
            )
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Account.self, from: data)
        XCTAssertEqual(decoded.pubkeyHex, original.pubkeyHex)
        XCTAssertEqual(decoded.petname, original.petname)
        XCTAssertEqual(decoded.addedAt, original.addedAt)
        XCTAssertEqual(decoded.profile?.displayName, original.profile?.displayName)
        XCTAssertEqual(decoded.profile?.pictureURL, original.profile?.pictureURL)
        XCTAssertEqual(decoded.profile?.fetchedAt, original.profile?.fetchedAt)
    }

    func testAccount_decodesWithoutOptionalFields() throws {
        // Minimum-shape JSON — only required fields. Used by reinstall
        // recovery (which seeds Account records from listAllPubkeys() with
        // no petname or profile cache).
        let json = #"{"pubkeyHex":"abc123","addedAt":1714500000.0}"#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Account.self, from: data)
        XCTAssertEqual(decoded.pubkeyHex, "abc123")
        XCTAssertEqual(decoded.addedAt, 1714500000.0)
        XCTAssertNil(decoded.petname)
        XCTAssertNil(decoded.profile)
    }

    func testAccount_idMatchesPubkeyHex() {
        // Identifiable conformance — id is used by SwiftUI ForEach/List
        // identity. Must equal pubkey so picker rows have stable identity
        // across petname/profile mutations.
        let acc = Account(pubkeyHex: "abc", petname: nil, addedAt: 0, profile: nil)
        XCTAssertEqual(acc.id, "abc")
    }

    func testAccount_equatable_isContentBased() {
        let a1 = Account(pubkeyHex: "abc", petname: "X", addedAt: 1, profile: nil)
        let a2 = Account(pubkeyHex: "abc", petname: "X", addedAt: 1, profile: nil)
        let a3 = Account(pubkeyHex: "abc", petname: "Y", addedAt: 1, profile: nil)
        XCTAssertEqual(a1, a2)
        XCTAssertNotEqual(a1, a3)
    }

    // MARK: - CachedProfile Codable (extracted from AppState)

    func testCachedProfile_codableRoundtrip() throws {
        let original = CachedProfile(
            displayName: "Alice",
            pictureURL: "https://example.com/a.png",
            fetchedAt: 1714500000.0
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CachedProfile.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCachedProfile_decodesPreviouslyStoredFormat() throws {
        // Verifies that pre-multi-account UserDefaults rows under
        // `cachedProfileKey` (single profile, before extraction to
        // Shared/SharedModels.swift) decode identically. No migration
        // step needed for this struct — only the storage location moves
        // (cachedProfileKey → Account.profile, in Task 8 migration).
        let json = #"{"displayName":"Bob","pictureURL":null,"fetchedAt":1700000000.0}"#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CachedProfile.self, from: data)
        XCTAssertEqual(decoded.displayName, "Bob")
        XCTAssertNil(decoded.pictureURL)
        XCTAssertEqual(decoded.fetchedAt, 1700000000.0)
    }

    // MARK: - SharedConstants keys

    func testSharedConstants_newMultiAccountKeys_existAndAreUnique() {
        // Guard against accidental key reuse — every key string must be
        // distinct across the SharedConstants namespace.
        let allKeys: Set<String> = [
            // Legacy keys (pre-multi-account) — must remain
            SharedConstants.signerPubkeyHexKey,
            SharedConstants.clientPubkeyHexKey,
            SharedConstants.deviceTokenKey,
            SharedConstants.proxyURLKey,
            SharedConstants.activityLogKey,
            SharedConstants.connectedClientsKey,
            SharedConstants.blockedKindsKey,
            SharedConstants.autoSignKey,
            SharedConstants.pendingRequestsKey,
            SharedConstants.pendingPairOpsKey,
            SharedConstants.bunkerSecretKey,
            SharedConstants.pairedClientsKey,
            SharedConstants.clientPermissionsKey,
            SharedConstants.cachedProfileKey,
            SharedConstants.lastContactSetKey,
            SharedConstants.lastRegisterSucceededAtKey,
            SharedConstants.lastRegisterFailedAtKey,
            // Multi-account additions (Task 1)
            SharedConstants.accountsKey,
            SharedConstants.currentSignerPubkeyHexKey,
            SharedConstants.bunkerSecretsKey,
            SharedConstants.lastContactSetsKey,
            SharedConstants.lastRegisterTimesKey,
        ]
        // 22 distinct entries. If any new key collides with an existing
        // string literal, the Set count drops and this fails.
        XCTAssertEqual(allKeys.count, 22)
    }

    func testSharedConstants_multiAccountKeys_areNamespaced() {
        // Sanity: the new keys don't accidentally shadow legacy ones via
        // typo. (e.g., bunkerSecretsKey vs bunkerSecretKey — easy to mix up.)
        XCTAssertNotEqual(SharedConstants.bunkerSecretKey, SharedConstants.bunkerSecretsKey)
        XCTAssertNotEqual(SharedConstants.signerPubkeyHexKey, SharedConstants.currentSignerPubkeyHexKey)
        XCTAssertNotEqual(SharedConstants.lastContactSetKey, SharedConstants.lastContactSetsKey)
    }
}
