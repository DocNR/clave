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

    func testCachedProfile_codableRoundtrip_preservesNewFields() throws {
        let original = CachedProfile(
            displayName: "Alice",
            pictureURL: "https://example.com/a.png",
            about: "Bitcoin and signal. Long-time relay operator.",
            nip05: "alice@example.com",
            lud16: "alice@strike.me",
            fetchedAt: 1700000000.0
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CachedProfile.self, from: data)
        XCTAssertEqual(decoded.displayName, "Alice")
        XCTAssertEqual(decoded.pictureURL, "https://example.com/a.png")
        XCTAssertEqual(decoded.about, "Bitcoin and signal. Long-time relay operator.")
        XCTAssertEqual(decoded.nip05, "alice@example.com")
        XCTAssertEqual(decoded.lud16, "alice@strike.me")
        XCTAssertEqual(decoded.fetchedAt, 1700000000.0)
    }

    func testCachedProfile_decodesLegacyFormat_missingNewFields() throws {
        // Pre-2026-05-03 on-disk blob — no about / nip05 / lud16 keys.
        // Codable's optional defaulting must keep these as nil; no migration.
        let json = #"{"displayName":"Bob","pictureURL":"https://example.com/b.png","fetchedAt":1700000000.0}"#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CachedProfile.self, from: data)
        XCTAssertEqual(decoded.displayName, "Bob")
        XCTAssertEqual(decoded.pictureURL, "https://example.com/b.png")
        XCTAssertNil(decoded.about)
        XCTAssertNil(decoded.nip05)
        XCTAssertNil(decoded.lud16)
    }

    func testCachedProfile_codable_omittedNewFields_decodeAsNil() throws {
        // Verify the init defaults work as expected when callers don't pass new fields.
        let original = CachedProfile(
            displayName: "Carol",
            pictureURL: nil,
            fetchedAt: 1700000000.0
        )
        XCTAssertNil(original.about)
        XCTAssertNil(original.nip05)
        XCTAssertNil(original.lud16)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CachedProfile.self, from: data)
        XCTAssertNil(decoded.about)
        XCTAssertNil(decoded.nip05)
        XCTAssertNil(decoded.lud16)
    }

    func testCachedProfile_encodedJSON_containsNewKeysWhenSet() throws {
        // Confirm the on-disk JSON shape carries the new fields (so a future
        // reinstall recovery or external tool can read them).
        let original = CachedProfile(
            displayName: "Dave",
            pictureURL: nil,
            about: "test bio",
            nip05: "dave@example.com",
            lud16: "dave@strike.me",
            fetchedAt: 1700000000.0
        )
        let data = try JSONEncoder().encode(original)
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(jsonString.contains("\"about\""), "JSON should contain about key")
        XCTAssertTrue(jsonString.contains("\"nip05\""), "JSON should contain nip05 key")
        XCTAssertTrue(jsonString.contains("\"lud16\""), "JSON should contain lud16 key")
    }

    func testCachedProfile_equatable_recognizesNewFieldDifferences() throws {
        // Equatable conformance must distinguish profiles that differ only
        // in the new fields (so SwiftUI re-render triggers when about/
        // nip05/lud16 change without displayName/pictureURL changing).
        let base = CachedProfile(
            displayName: "Eve",
            pictureURL: "https://example.com/e.png",
            about: "first bio",
            nip05: "eve@example.com",
            lud16: "eve@strike.me",
            fetchedAt: 1700000000.0
        )
        var changedAbout = base; changedAbout.about = "second bio"
        var changedNip05 = base; changedNip05.nip05 = "eve@other.com"
        var changedLud16 = base; changedLud16.lud16 = "eve@cashapp.com"
        XCTAssertNotEqual(base, changedAbout)
        XCTAssertNotEqual(base, changedNip05)
        XCTAssertNotEqual(base, changedLud16)
        XCTAssertEqual(base, base)
    }

    func testCachedProfile_codable_preservesNameField() throws {
        // The `name` field (kind:0 short handle) is distinct from displayName
        // (the long human-readable name).
        let original = CachedProfile(
            displayName: "Frank Smith",
            name: "frank",
            pictureURL: nil,
            fetchedAt: 1700000000.0
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CachedProfile.self, from: data)
        XCTAssertEqual(decoded.displayName, "Frank Smith")
        XCTAssertEqual(decoded.name, "frank")
    }

    func testCachedProfile_decodesLegacyFormat_missingNameField() throws {
        // Pre-build-46 on-disk blob — has displayName but no `name` key.
        // Codable's optional defaulting must keep `name` as nil; no migration.
        let json = #"{"displayName":"Grace","pictureURL":"https://example.com/g.png","fetchedAt":1700000000.0}"#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CachedProfile.self, from: data)
        XCTAssertEqual(decoded.displayName, "Grace")
        XCTAssertNil(decoded.name)
    }

    // MARK: - Account.displayLabel (build 46 chain: displayName → name → prefix)

    func testAccount_displayLabel_prefersDisplayNameOverPetname() throws {
        // Build 46: petname is intentionally ignored even when set.
        // displayName from kind:0 takes precedence.
        let acc = Account(
            pubkeyHex: "abc123def456abc123def456abc123def456abc123def456abc123def456abcd",
            petname: "Legacy Petname",
            addedAt: 1714500000.0,
            profile: CachedProfile(displayName: "Display Name", fetchedAt: 1714500000.0)
        )
        XCTAssertEqual(acc.displayLabel, "Display Name")
    }

    func testAccount_displayLabel_fallsBackToNameWhenNoDisplayName() throws {
        // displayName missing → falls back to kind:0 short name (handle).
        let acc = Account(
            pubkeyHex: "abc123def456abc123def456abc123def456abc123def456abc123def456abcd",
            petname: nil,
            addedAt: 1714500000.0,
            profile: CachedProfile(name: "shorthandle", fetchedAt: 1714500000.0)
        )
        XCTAssertEqual(acc.displayLabel, "shorthandle")
    }

    func testAccount_displayLabel_ignoresPetname_usesPubkeyPrefixWhenNoProfile() throws {
        // No profile cached at all — falls through to npub prefix.
        // Petname is set but should be ignored.
        let acc = Account(
            pubkeyHex: "abc123def456abc123def456abc123def456abc123def456abc123def456abcd",
            petname: "ShouldBeIgnored",
            addedAt: 1714500000.0,
            profile: nil
        )
        XCTAssertEqual(acc.displayLabel, "abc123de")
    }

    func testAccount_displayLabel_prefersDisplayNameOverName() throws {
        // When both displayName and name are set, displayName wins.
        let acc = Account(
            pubkeyHex: "abc123def456abc123def456abc123def456abc123def456abc123def456abcd",
            petname: nil,
            addedAt: 1714500000.0,
            profile: CachedProfile(
                displayName: "Alice Smith",
                name: "alice",
                fetchedAt: 1714500000.0
            )
        )
        XCTAssertEqual(acc.displayLabel, "Alice Smith")
    }

    func testAccount_displayLabel_usesPubkeyPrefixWhenProfileEmpty() throws {
        // Profile exists but all identity fields are empty/nil — fall through
        // to 8-char pubkey prefix.
        let acc = Account(
            pubkeyHex: "abc123def456abc123def456abc123def456abc123def456abc123def456abcd",
            petname: nil,
            addedAt: 1714500000.0,
            profile: CachedProfile(fetchedAt: 1714500000.0)
        )
        XCTAssertEqual(acc.displayLabel, "abc123de")
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
