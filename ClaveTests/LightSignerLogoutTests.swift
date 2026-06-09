import XCTest
@testable import Clave

/// NIP-46 logout — replay-guard coverage. `isLogoutReplay` is pure, tested
/// directly. The handleRequest gate (which reuses these) is exercised via the
/// async path + manual verification.
final class LightSignerLogoutTests: XCTestCase {

    let testSigner = "logoutSigner"
    let testClient = "logoutClient"

    override func setUp() { super.setUp(); wipeKeys() }
    override func tearDown() { wipeKeys(); super.tearDown() }

    private func wipeKeys() {
        let keys = [
            SharedConstants.connectedClientsKey,
            SharedConstants.clientPermissionsKey,
            SharedConstants.activityLogKey,
            SharedConstants.pendingPairOpsKey,
        ]
        for k in keys { SharedConstants.sharedDefaults.removeObject(forKey: k) }
    }

    private func seedPairedClient() {
        let perms = ClientPermissions(
            pubkey: testClient, trustLevel: .medium, kindOverrides: [:],
            methodPermissions: ClientPermissions.defaultMethodPermissions,
            name: "Test Client", url: nil, imageURL: nil,
            connectedAt: Date().timeIntervalSince1970, lastSeen: Date().timeIntervalSince1970,
            requestCount: 0, signerPubkeyHex: testSigner)
        SharedStorage.saveClientPermissions(perms)
        SharedStorage.setClientRelayUrls(pubkey: testClient, relayUrls: [SharedConstants.relayURL], signer: testSigner)
    }

    private func seedActivityEntry() {
        let entry = ActivityEntry(
            id: "act-1", method: "sign_event", eventKind: 1, clientPubkey: testClient,
            timestamp: Date().timeIntervalSince1970, status: "signed", errorMessage: nil,
            signerPubkeyHex: testSigner)
        SharedStorage.logActivity(entry)
    }

    func testLogoutTeardown_removesPairAndConnectedRow() async {
        seedPairedClient()
        XCTAssertNotNil(SharedStorage.getClientPermissions(signer: testSigner, client: testClient))
        XCTAssertEqual(SharedStorage.getConnectedClients(for: testSigner).count, 1)
        await LightSigner.performLogoutTeardown(signerPubkey: testSigner, senderPubkey: testClient)
        XCTAssertNil(SharedStorage.getClientPermissions(signer: testSigner, client: testClient))
        XCTAssertEqual(SharedStorage.getConnectedClients(for: testSigner).count, 0)
    }

    func testLogoutTeardown_retainsActivityLog() async {
        seedPairedClient(); seedActivityEntry()
        XCTAssertEqual(SharedStorage.getActivityLog(for: testSigner).count, 1)
        await LightSigner.performLogoutTeardown(signerPubkey: testSigner, senderPubkey: testClient)
        XCTAssertEqual(SharedStorage.getActivityLog(for: testSigner).count, 1,
                       "logout must KEEP the activity log (parity with manual unpair)")
    }

    /// No reachable proxy in tests → the inline POST fails and falls back to the
    /// PairOp queue, so the queued op is the observable outcome.
    func testLogoutTeardown_queuesProxyUnpairOnFailure() async {
        seedPairedClient()
        await LightSigner.performLogoutTeardown(signerPubkey: testSigner, senderPubkey: testClient)
        let ops = SharedStorage.getPendingPairOps()
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops.first?.kind, .unpair)
        XCTAssertEqual(ops.first?.clientPubkey, testClient)
        XCTAssertEqual(ops.first?.signerPubkeyHex, testSigner)
    }

    func testLogoutTeardown_secondCallIsNoOp() async {
        seedPairedClient()
        await LightSigner.performLogoutTeardown(signerPubkey: testSigner, senderPubkey: testClient)
        let afterFirst = SharedStorage.getPendingPairOps().count
        await LightSigner.performLogoutTeardown(signerPubkey: testSigner, senderPubkey: testClient)
        XCTAssertEqual(SharedStorage.getPendingPairOps().count, afterFirst,
                       "second teardown (pair already gone) must not enqueue a duplicate op")
    }

    func testIsLogoutReplay_rejectsFramePredatingPairing() {
        // pairing at t=10_000; a replayed logout from a prior session at t=9_000.
        XCTAssertTrue(LightSigner.isLogoutReplay(eventCreatedAt: 9_000, pairingConnectedAt: 10_000))
    }

    func testIsLogoutReplay_acceptsFreshLogout() {
        // logout sent after pairing (plus normal delay) is honored.
        XCTAssertFalse(LightSigner.isLogoutReplay(eventCreatedAt: 10_500, pairingConnectedAt: 10_000))
    }

    func testIsLogoutReplay_toleratesClockSkew() {
        // logout 100s "before" connectedAt (clock skew) within the 300s tolerance is honored.
        XCTAssertFalse(LightSigner.isLogoutReplay(eventCreatedAt: 9_900, pairingConnectedAt: 10_000))
    }
}
