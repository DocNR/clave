import XCTest
@testable import Clave

/// Sprint 5a regression coverage. Documents the post-fix invariant that a
/// successful bunker first-connect must populate a `ConnectedClient` row
/// in the same logical step as `ClientPermissions`, so that
/// `SharedStorage.getConnectedClients(for:)` reflects the new pair before
/// the next bunker connect's cap-check at
/// [LightSigner.swift:175-176](../Shared/LightSigner.swift) runs.
///
/// Pre-fix bug: bunker first-connect saved `ClientPermissions` but
/// deferred `ConnectedClient` row creation until the first signing
/// request arrived (via `SharedStorage.updateClient`). Multiple bunker
/// pairs landed before any of them counted toward the 5-cap, allowing 7+
/// pairs in field testing on build 63.
///
/// These tests don't drive the full NSE handshake (LightSigner is async +
/// Network-dependent); they verify the SharedStorage invariants the fix
/// relies on.
final class LightSignerBunkerConnectTests: XCTestCase {

    let testSigner = "testSigner5a"
    let testClient = "testClient5a"

    override func setUp() {
        super.setUp()
        wipeKeys()
    }

    override func tearDown() {
        wipeKeys()
        super.tearDown()
    }

    private func wipeKeys() {
        let keys = [
            SharedConstants.connectedClientsKey,
            SharedConstants.clientPermissionsKey,
        ]
        for k in keys { SharedConstants.sharedDefaults.removeObject(forKey: k) }
    }

    // MARK: - 5a-core invariant

    /// After saving ClientPermissions and calling setClientRelayUrls with the
    /// bunker URI's relay, getConnectedClients(for:) returns the new client
    /// with relayUrls populated. This is the exact post-fix sequence
    /// LightSigner runs at line 209.
    func testBunkerConnect_createsConnectedClientRow_withBunkerURIRelay() {
        let perms = ClientPermissions(
            pubkey: testClient,
            trustLevel: .medium,
            kindOverrides: [:],
            methodPermissions: ClientPermissions.defaultMethodPermissions,
            name: nil,
            url: nil,
            imageURL: nil,
            connectedAt: Date().timeIntervalSince1970,
            lastSeen: Date().timeIntervalSince1970,
            requestCount: 0,
            signerPubkeyHex: testSigner
        )
        SharedStorage.saveClientPermissions(perms)
        SharedStorage.setClientRelayUrls(
            pubkey: testClient,
            relayUrls: [SharedConstants.relayURL],
            signer: testSigner
        )

        let clients = SharedStorage.getConnectedClients(for: testSigner)
        XCTAssertEqual(clients.count, 1)
        XCTAssertEqual(clients.first?.pubkey, testClient)
        XCTAssertEqual(clients.first?.signerPubkeyHex, testSigner)
        XCTAssertTrue(clients.first?.relayUrls.contains(SharedConstants.relayURL) ?? false,
                      "Bunker URI relay should be persisted on the row so L1's relay-set computation picks it up")
    }

    /// 6th bunker pair attempt must trip the >= cap guard at
    /// LightSigner.swift:176. Pre-populating 5 rows simulates the
    /// post-fix steady state; the cap-check is reproduced here as the
    /// same boolean predicate so the test fails if either side drifts.
    func testBunkerConnect_capCheckBlocksAtFiveExistingRows() {
        for i in 0..<5 {
            let pk = "\(testClient)_\(i)"
            SharedStorage.setClientRelayUrls(
                pubkey: pk,
                relayUrls: [SharedConstants.relayURL],
                signer: testSigner
            )
        }
        let count = SharedStorage.getConnectedClients(for: testSigner).count
        XCTAssertEqual(count, 5)
        XCTAssertGreaterThanOrEqual(count, Account.maxClientsPerAccount,
                                    "Cap-check guard at LightSigner.swift:176 fires here in production")
    }

    /// Re-pairing the same (signer, client) pair shouldn't double-count:
    /// setClientRelayUrls is keyed on (signerPubkeyHex, pubkey), so a
    /// repeat call mutates the existing row rather than appending. This
    /// guards against the cap inflating after a client reconnects.
    func testBunkerConnect_rePairSameClient_doesNotDoubleCount() {
        SharedStorage.setClientRelayUrls(
            pubkey: testClient,
            relayUrls: [SharedConstants.relayURL],
            signer: testSigner
        )
        SharedStorage.setClientRelayUrls(
            pubkey: testClient,
            relayUrls: [SharedConstants.relayURL],
            signer: testSigner
        )
        XCTAssertEqual(SharedStorage.getConnectedClients(for: testSigner).count, 1)
    }

    /// Per-signer scoping: rows for one signer don't leak into the count for
    /// another signer. Confirms the pre-existing scoping survives the fix.
    func testBunkerConnect_perSignerScoping_doesNotLeakCount() {
        for i in 0..<5 {
            SharedStorage.setClientRelayUrls(
                pubkey: "\(testClient)_\(i)",
                relayUrls: [SharedConstants.relayURL],
                signer: testSigner
            )
        }
        XCTAssertEqual(SharedStorage.getConnectedClients(for: "otherSigner").count, 0)
        XCTAssertEqual(SharedStorage.getConnectedClients(for: testSigner).count, 5)
    }
}
