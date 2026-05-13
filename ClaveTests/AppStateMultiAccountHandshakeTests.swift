import XCTest
@testable import Clave

/// N-up handshake loop semantics. Live-relay handshake is impractical to
/// unit test (requires real relay + nsec). These tests verify the
/// loop-coordination layer: HandshakeResult accumulation, partial-failure
/// shape, empty-input boundary.
final class AppStateMultiAccountHandshakeTests: XCTestCase {

    @MainActor
    func testEmptyArrayThrowsAtBoundary() async throws {
        let appState = AppState()
        let dummyURI = try NostrConnectParser.parse(
            "nostrconnect://aabbccdd?relay=wss%3A%2F%2Frelay.example.com&secret=s"
        )
        let perms = ClientPermissions(
            pubkey: "aabbccdd",
            trustLevel: .medium,
            kindOverrides: [:],
            methodPermissions: ClientPermissions.defaultMethodPermissions,
            name: nil,
            connectedAt: Date().timeIntervalSince1970,
            lastSeen: Date().timeIntervalSince1970,
            requestCount: 0,
            signerPubkeyHex: ""
        )
        do {
            _ = try await appState.handleNostrConnect(
                parsedURI: dummyURI,
                signerPubkeys: [],
                permissions: perms
            )
            XCTFail("Expected throw on empty signerPubkeys")
        } catch ClaveError.noSignerKey {
            // expected
        }
    }

    @MainActor
    func testAllFailure_AccumulatesAllPubkeysIntoFailed() async throws {
        // Two signer pubkeys that don't exist in the keychain → every
        // iteration throws at the nsec-load step → both end up in
        // HandshakeResult.failed with correct signerPubkey attribution.
        let appState = AppState()
        let dummyURI = try NostrConnectParser.parse(
            "nostrconnect://aabbccdd?relay=wss%3A%2F%2Frelay.invalid.test&secret=s"
        )
        let perms = ClientPermissions(
            pubkey: "aabbccdd",
            trustLevel: .medium,
            kindOverrides: [:],
            methodPermissions: ClientPermissions.defaultMethodPermissions,
            name: nil,
            connectedAt: Date().timeIntervalSince1970,
            lastSeen: Date().timeIntervalSince1970,
            requestCount: 0,
            signerPubkeyHex: ""
        )
        let result = try await appState.handleNostrConnect(
            parsedURI: dummyURI,
            signerPubkeys: ["nonexistent-pk-1", "nonexistent-pk-2"],
            permissions: perms
        )
        XCTAssertEqual(result.succeeded.count, 0)
        XCTAssertEqual(result.failed.count, 2)
        XCTAssertEqual(result.failed.map(\.signerPubkey), ["nonexistent-pk-1", "nonexistent-pk-2"])
        XCTAssertTrue(result.isAllFailure)
        XCTAssertFalse(result.isPartialFailure)
        XCTAssertFalse(result.isAllSuccess)
    }
}
