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

    // MARK: - Task 8.5 — per-signer ClientPermissions rewrite helper

    /// `ClientPermissions.with(signerPubkeyHex:)` is the cloning primitive
    /// runSingleConnect uses to produce N distinct rows from one template
    /// — one per signer in the multi-account handshake loop. Without this,
    /// all N iterations overwrite the same row (the composite key is
    /// `(signerPubkeyHex, pubkey)` in SharedStorage) and signers 2…N end
    /// up with no ClientPermissions entry → their requests get rejected.
    /// These tests pin the helper's contract: signerPubkeyHex is the only
    /// field that changes; every other field is preserved verbatim.
    func testWithSignerPubkeyHex_RewritesOnlySignerField() {
        let original = ClientPermissions(
            pubkey: "client-pk",
            trustLevel: .medium,
            kindOverrides: [1: true, 3: false],
            methodPermissions: ["nip04_encrypt", "nip44_decrypt"],
            name: "TestClient",
            url: "https://example.com",
            imageURL: "https://example.com/img.png",
            connectedAt: 1_700_000_000,
            lastSeen: 1_700_000_100,
            requestCount: 7,
            signerPubkeyHex: "signer-A"
        )

        let rewritten = original.with(signerPubkeyHex: "signer-B")

        // Only signerPubkeyHex changes.
        XCTAssertEqual(rewritten.signerPubkeyHex, "signer-B")
        XCTAssertEqual(original.signerPubkeyHex, "signer-A", "Helper must not mutate the source")

        // Every other field copies verbatim.
        XCTAssertEqual(rewritten.pubkey, original.pubkey)
        XCTAssertEqual(rewritten.trustLevel, original.trustLevel)
        XCTAssertEqual(rewritten.kindOverrides, original.kindOverrides)
        XCTAssertEqual(rewritten.methodPermissions, original.methodPermissions)
        XCTAssertEqual(rewritten.name, original.name)
        XCTAssertEqual(rewritten.url, original.url)
        XCTAssertEqual(rewritten.imageURL, original.imageURL)
        XCTAssertEqual(rewritten.connectedAt, original.connectedAt)
        XCTAssertEqual(rewritten.lastSeen, original.lastSeen)
        XCTAssertEqual(rewritten.requestCount, original.requestCount)
    }

    func testWithSignerPubkeyHex_ProducesDistinctCompositeIds() {
        // The fix's load-bearing invariant: rewriting signerPubkeyHex on
        // copies of a single template produces ClientPermissions instances
        // whose composite `id` ("<signer>:<client>") differs per signer —
        // which is exactly what SharedStorage.saveClientPermissions keys on
        // to decide insert-vs-overwrite. If composite ids collide, N
        // iterations overwrite each other (the bug Task 8.5 fixes).
        let template = ClientPermissions(
            pubkey: "client-pk",
            trustLevel: .medium,
            kindOverrides: [:],
            methodPermissions: ClientPermissions.defaultMethodPermissions,
            connectedAt: Date().timeIntervalSince1970,
            lastSeen: Date().timeIntervalSince1970,
            requestCount: 0,
            signerPubkeyHex: "signer-A" // placeholder — caller rewrites per signer
        )
        let forA = template.with(signerPubkeyHex: "signer-A")
        let forB = template.with(signerPubkeyHex: "signer-B")
        let forC = template.with(signerPubkeyHex: "signer-C")
        let ids = Set([forA.id, forB.id, forC.id])
        XCTAssertEqual(ids.count, 3, "Per-signer copies must have distinct composite ids")
        XCTAssertEqual(forA.id, "signer-A:client-pk")
        XCTAssertEqual(forB.id, "signer-B:client-pk")
        XCTAssertEqual(forC.id, "signer-C:client-pk")
    }
}
