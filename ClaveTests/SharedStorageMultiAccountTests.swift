import XCTest
@testable import Clave

/// Task 4 of the multi-account sprint (`feat/multi-account`).
///
/// Verifies the new `SharedStorage` per-signer surface:
/// - Filtered readers (`getActivityLog(for:)` etc.)
/// - Composite-key writers (`saveClientPermissions` matches on
///   `(signer, client)`)
/// - Scoped writers (`removeClientPermissions(signer:client:)`,
///   `touchClient(pubkey:signer:)`, `unpairAllClients(for:)`)
/// - Per-signer bunker secrets, last-contact-set snapshots, register
///   timestamps
///
/// Plan: ~/hq/clave/plans/2026-04-30-multi-account-sprint.md
final class SharedStorageMultiAccountTests: XCTestCase {

    // Fake placeholder signer/client identifiers — not real pubkeys.
    // SharedStorage doesn't validate format at this layer; tests don't
    // need realistic 64-char hex.
    let signerA = "signerA"
    let signerB = "signerB"
    let clientX = "clientX"
    let clientY = "clientY"

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
            SharedConstants.activityLogKey,
            SharedConstants.pendingRequestsKey,
            SharedConstants.connectedClientsKey,
            SharedConstants.clientPermissionsKey,
            SharedConstants.pendingPairOpsKey,
            SharedConstants.bunkerSecretsKey,
            SharedConstants.bunkerSecretKey,        // legacy
            SharedConstants.lastContactSetsKey,
            SharedConstants.lastContactSetKey,      // legacy
            SharedConstants.lastRegisterTimesKey,
            SharedConstants.lastRegisterSucceededAtKey,  // legacy
            SharedConstants.lastRegisterFailedAtKey,     // legacy
        ]
        for k in keys { SharedConstants.sharedDefaults.removeObject(forKey: k) }
    }

    // MARK: - Filtered readers

    func testActivityLog_filterBySigner_omitsOtherSigners() {
        SharedStorage.logActivity(ActivityEntry(
            id: "1", method: "sign_event", eventKind: 1, clientPubkey: clientX,
            timestamp: 1, status: "signed", errorMessage: nil,
            signerPubkeyHex: signerA
        ))
        SharedStorage.logActivity(ActivityEntry(
            id: "2", method: "sign_event", eventKind: 1, clientPubkey: clientX,
            timestamp: 2, status: "signed", errorMessage: nil,
            signerPubkeyHex: signerB
        ))
        XCTAssertEqual(SharedStorage.getActivityLog(for: signerA).count, 1)
        XCTAssertEqual(SharedStorage.getActivityLog(for: signerA).first?.id, "1")
        XCTAssertEqual(SharedStorage.getActivityLog(for: signerB).count, 1)
        // Unfiltered reader still returns all rows (used by merged views in
        // Phase 2)
        XCTAssertEqual(SharedStorage.getActivityLog().count, 2)
    }

    func testActivityLog_legacyEmptySigner_notSurfacedByFilteredReader() {
        // Legacy row: signerPubkeyHex defaults to "" (Task 3 behavior)
        SharedStorage.logActivity(ActivityEntry(
            id: "legacy", method: "x", eventKind: nil, clientPubkey: clientX,
            timestamp: 1, status: "signed", errorMessage: nil
            // signerPubkeyHex omitted → defaults to ""
        ))
        XCTAssertEqual(SharedStorage.getActivityLog(for: signerA).count, 0,
                       "Filtered reader must NOT match empty-signer legacy rows")
        // Unfiltered shows it (intentional — merged views still see legacy data)
        XCTAssertEqual(SharedStorage.getActivityLog().count, 1)
    }

    func testPendingRequests_filterBySigner() {
        SharedStorage.queuePendingRequest(PendingRequest(
            id: "1", requestEventJSON: "{}", method: "sign_event",
            eventKind: 1, clientPubkey: clientX, timestamp: 1,
            responseRelayUrl: nil, signerPubkeyHex: signerA
        ))
        SharedStorage.queuePendingRequest(PendingRequest(
            id: "2", requestEventJSON: "{}", method: "sign_event",
            eventKind: 1, clientPubkey: clientX, timestamp: 2,
            responseRelayUrl: nil, signerPubkeyHex: signerB
        ))
        XCTAssertEqual(SharedStorage.getPendingRequests(for: signerA).count, 1)
        XCTAssertEqual(SharedStorage.getPendingRequests().count, 2)
    }

    func testClientPermissions_filteredByCompositeKey() {
        let pA = ClientPermissions(
            pubkey: clientX, trustLevel: .full,
            kindOverrides: [:], methodPermissions: [],
            connectedAt: 0, lastSeen: 0, requestCount: 0,
            signerPubkeyHex: signerA
        )
        let pB = ClientPermissions(
            pubkey: clientX, trustLevel: .medium,
            kindOverrides: [:], methodPermissions: [],
            connectedAt: 0, lastSeen: 0, requestCount: 0,
            signerPubkeyHex: signerB
        )
        SharedStorage.saveClientPermissions(pA)
        SharedStorage.saveClientPermissions(pB)

        // Per-signer reader returns only that signer's rows
        XCTAssertEqual(SharedStorage.getClientPermissions(forSigner: signerA).count, 1)
        XCTAssertEqual(SharedStorage.getClientPermissions(forSigner: signerA).first?.trustLevel, .full)
        XCTAssertEqual(SharedStorage.getClientPermissions(forSigner: signerB).first?.trustLevel, .medium)

        // Composite-key fetch
        XCTAssertEqual(
            SharedStorage.getClientPermissions(signer: signerA, client: clientX)?.trustLevel,
            .full
        )
        XCTAssertEqual(
            SharedStorage.getClientPermissions(signer: signerB, client: clientX)?.trustLevel,
            .medium
        )
    }

    // MARK: - Scoped writers (composite-key match preserves cross-signer rows)

    func testSaveClientPermissions_compositeMatch_doesNotClobberOtherSigner() {
        let pA = ClientPermissions(
            pubkey: clientX, trustLevel: .full,
            kindOverrides: [:], methodPermissions: [],
            name: "from-A",
            connectedAt: 0, lastSeen: 0, requestCount: 5,
            signerPubkeyHex: signerA
        )
        let pB = ClientPermissions(
            pubkey: clientX, trustLevel: .medium,
            kindOverrides: [:], methodPermissions: [],
            name: "from-B",
            connectedAt: 0, lastSeen: 0, requestCount: 1,
            signerPubkeyHex: signerB
        )
        SharedStorage.saveClientPermissions(pA)
        SharedStorage.saveClientPermissions(pB)

        // Update pA — pB must remain untouched
        let pAUpdated = ClientPermissions(
            pubkey: clientX, trustLevel: .full,
            kindOverrides: [:], methodPermissions: [],
            name: "from-A-updated",
            connectedAt: 0, lastSeen: 0, requestCount: 99,
            signerPubkeyHex: signerA
        )
        SharedStorage.saveClientPermissions(pAUpdated)

        XCTAssertEqual(SharedStorage.getClientPermissions(signer: signerA, client: clientX)?.requestCount, 99)
        XCTAssertEqual(SharedStorage.getClientPermissions(signer: signerA, client: clientX)?.name, "from-A-updated")
        // pB unchanged
        XCTAssertEqual(SharedStorage.getClientPermissions(signer: signerB, client: clientX)?.requestCount, 1)
        XCTAssertEqual(SharedStorage.getClientPermissions(signer: signerB, client: clientX)?.name, "from-B")
    }

    func testTouchClient_scoped_onlyTouchesMatchingSigner() {
        let pA = ClientPermissions(
            pubkey: clientX, trustLevel: .full,
            kindOverrides: [:], methodPermissions: [],
            connectedAt: 0, lastSeen: 0, requestCount: 0,
            signerPubkeyHex: signerA
        )
        let pB = ClientPermissions(
            pubkey: clientX, trustLevel: .full,
            kindOverrides: [:], methodPermissions: [],
            connectedAt: 0, lastSeen: 0, requestCount: 0,
            signerPubkeyHex: signerB
        )
        SharedStorage.saveClientPermissions(pA)
        SharedStorage.saveClientPermissions(pB)

        SharedStorage.touchClient(pubkey: clientX, signer: signerA)

        XCTAssertEqual(SharedStorage.getClientPermissions(signer: signerA, client: clientX)?.requestCount, 1)
        XCTAssertEqual(SharedStorage.getClientPermissions(signer: signerB, client: clientX)?.requestCount, 0,
                       "touchClient must not increment the wrong signer's row")
    }

    func testRemoveClientPermissions_scoped_doesNotRemoveOtherSigner() {
        let pA = ClientPermissions(
            pubkey: clientX, trustLevel: .full,
            kindOverrides: [:], methodPermissions: [],
            connectedAt: 0, lastSeen: 0, requestCount: 0,
            signerPubkeyHex: signerA
        )
        let pB = ClientPermissions(
            pubkey: clientX, trustLevel: .full,
            kindOverrides: [:], methodPermissions: [],
            connectedAt: 0, lastSeen: 0, requestCount: 0,
            signerPubkeyHex: signerB
        )
        SharedStorage.saveClientPermissions(pA)
        SharedStorage.saveClientPermissions(pB)

        SharedStorage.removeClientPermissions(signer: signerA, client: clientX)

        XCTAssertNil(SharedStorage.getClientPermissions(signer: signerA, client: clientX))
        XCTAssertNotNil(SharedStorage.getClientPermissions(signer: signerB, client: clientX),
                        "Sibling signer's row must survive scoped removal")
    }

    func testUnpairAllClients_scoped_onlyClearsThatSigner() {
        SharedStorage.saveClientPermissions(ClientPermissions(
            pubkey: clientX, trustLevel: .full,
            kindOverrides: [:], methodPermissions: [],
            connectedAt: 0, lastSeen: 0, requestCount: 0,
            signerPubkeyHex: signerA
        ))
        SharedStorage.saveClientPermissions(ClientPermissions(
            pubkey: clientY, trustLevel: .full,
            kindOverrides: [:], methodPermissions: [],
            connectedAt: 0, lastSeen: 0, requestCount: 0,
            signerPubkeyHex: signerB
        ))

        SharedStorage.unpairAllClients(for: signerA)

        XCTAssertEqual(SharedStorage.getClientPermissions(forSigner: signerA).count, 0)
        XCTAssertEqual(SharedStorage.getClientPermissions(forSigner: signerB).count, 1,
                       "unpairAllClients(for: signerA) must NEVER touch signerB's rows")
    }

    // MARK: - Per-signer bunker secrets

    func testBunkerSecret_perSigner_independentRotation() {
        let s1 = SharedStorage.getBunkerSecret(for: signerA)
        let s2 = SharedStorage.getBunkerSecret(for: signerB)
        XCTAssertNotEqual(s1, s2, "Two signers must get distinct bunker secrets")
        // Stable across reads
        XCTAssertEqual(SharedStorage.getBunkerSecret(for: signerA), s1)

        let s1Rotated = SharedStorage.rotateBunkerSecret(for: signerA)
        XCTAssertNotEqual(s1Rotated, s1)
        // Sibling signer unaffected
        XCTAssertEqual(SharedStorage.getBunkerSecret(for: signerB), s2)
    }

    func testBunkerSecret_legacyKey_seedsFirstAccountOnRead() {
        // Defense-in-depth: simulate pre-Task-8-migration state. Legacy
        // global secret exists; per-signer dict is empty. First signer
        // to read inherits the legacy secret.
        SharedConstants.sharedDefaults.set("legacyhex", forKey: SharedConstants.bunkerSecretKey)
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.bunkerSecretsKey)

        let read = SharedStorage.getBunkerSecret(for: signerA)
        XCTAssertEqual(read, "legacyhex")
        // Persisted; subsequent reads return same value
        XCTAssertEqual(SharedStorage.getBunkerSecret(for: signerA), "legacyhex")
    }

    // MARK: - Per-signer last-contact-set (PR #19 cross-account corruption fix)

    func testLastContactSet_perSigner_independent() {
        let setA: Set<String> = ["pubA1", "pubA2"]
        let setB: Set<String> = ["pubB1", "pubB2", "pubB3"]
        SharedStorage.saveLastContactSet(setA, for: signerA)
        SharedStorage.saveLastContactSet(setB, for: signerB)

        XCTAssertEqual(SharedStorage.getLastContactSet(for: signerA), setA)
        XCTAssertEqual(SharedStorage.getLastContactSet(for: signerB), setB)

        // Updating A doesn't affect B (the bug we're preventing)
        SharedStorage.saveLastContactSet(["pubA1"], for: signerA)
        XCTAssertEqual(SharedStorage.getLastContactSet(for: signerA), ["pubA1"])
        XCTAssertEqual(SharedStorage.getLastContactSet(for: signerB), setB,
                       "Account B's snapshot must not be clobbered by Account A's kind:3 sign")
    }

    func testLastContactSet_clearForOneSigner() {
        SharedStorage.saveLastContactSet(["x"], for: signerA)
        SharedStorage.saveLastContactSet(["y"], for: signerB)
        SharedStorage.saveLastContactSet(nil, for: signerA)
        XCTAssertNil(SharedStorage.getLastContactSet(for: signerA))
        XCTAssertEqual(SharedStorage.getLastContactSet(for: signerB), ["y"],
                       "Clearing one signer must not affect another")
    }

    // MARK: - Per-signer register timestamps

    func testRegisterTimestamps_perSigner() {
        SharedStorage.setLastRegisterSucceededAt(1000, for: signerA)
        SharedStorage.setLastRegisterSucceededAt(2000, for: signerB)
        SharedStorage.setLastRegisterFailedAt(500, for: signerA)

        XCTAssertEqual(SharedStorage.getLastRegisterSucceededAt(for: signerA), 1000)
        XCTAssertEqual(SharedStorage.getLastRegisterSucceededAt(for: signerB), 2000)
        XCTAssertEqual(SharedStorage.getLastRegisterFailedAt(for: signerA), 500)
        XCTAssertNil(SharedStorage.getLastRegisterFailedAt(for: signerB),
                     "Sibling signer's failed timestamp is independent")
    }
}
