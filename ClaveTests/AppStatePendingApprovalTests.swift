import XCTest
@testable import Clave

/// Verifies the new pending-approval surface added for the
/// improve-approve-pending-flow sprint:
/// - 5-min TTL filter via `freshPendingRequests` / `activeApprovalRequest` /
///   `pendingApprovalQueueDepth` computed properties
/// - Hard purge via `purgeStalePendingRequests` writing "expired"
///   ActivityEntry rows
/// - `setKindOverride` helper used by `PendingRequestDetailView`'s
///   "Always allow this kind" toggle
///
/// These tests exercise local state only (UserDefaults). The lock-screen
/// action routing path is verified by `LockScreenActionRoutingTests`;
/// approve/deny end-to-end is verified by manual TestFlight smoke.
final class AppStatePendingApprovalTests: XCTestCase {

    private var appState: AppState!
    private let testSigner = "11" + String(repeating: "0", count: 62)
    private let testClient = "22" + String(repeating: "0", count: 62)

    override func setUp() {
        super.setUp()
        wipeKeys()
        appState = AppState()
    }

    override func tearDown() {
        wipeKeys()
        appState = nil
        super.tearDown()
    }

    private func wipeKeys() {
        let defaults = SharedConstants.sharedDefaults
        defaults.removeObject(forKey: SharedConstants.pendingRequestsKey)
        defaults.removeObject(forKey: SharedConstants.activityLogKey)
        defaults.removeObject(forKey: SharedConstants.clientPermissionsKey)
    }

    private func makeRequest(id: String, ageSeconds: Double, kind: Int? = 1) -> PendingRequest {
        PendingRequest(
            id: id,
            requestEventJSON: "{}",
            method: "sign_event",
            eventKind: kind,
            clientPubkey: testClient,
            timestamp: Date().timeIntervalSince1970 - ageSeconds,
            responseRelayUrl: nil,
            signerPubkeyHex: testSigner
        )
    }

    // MARK: - Computed property freshness filter

    func test_freshPendingRequests_filtersStale() {
        let fresh = makeRequest(id: "fresh", ageSeconds: 30)
        let stale = makeRequest(id: "stale", ageSeconds: 600)
        SharedStorage.queuePendingRequest(stale)
        SharedStorage.queuePendingRequest(fresh)
        appState.pendingRequests = SharedStorage.getPendingRequests()

        let ids = appState.freshPendingRequests.map { $0.id }
        XCTAssertEqual(ids, ["fresh"], "Stale request must be filtered out of freshPendingRequests")
    }

    func test_activeApprovalRequest_returnsFirstFreshRequest() {
        let first = makeRequest(id: "first", ageSeconds: 60)
        let second = makeRequest(id: "second", ageSeconds: 30)
        SharedStorage.queuePendingRequest(first)
        SharedStorage.queuePendingRequest(second)
        appState.pendingRequests = SharedStorage.getPendingRequests()

        XCTAssertEqual(appState.activeApprovalRequest?.id, "first",
                       "activeApprovalRequest must return the head of freshPendingRequests")
    }

    func test_activeApprovalRequest_isNilWhenAllStale() {
        let stale1 = makeRequest(id: "s1", ageSeconds: 600)
        let stale2 = makeRequest(id: "s2", ageSeconds: 700)
        SharedStorage.queuePendingRequest(stale1)
        SharedStorage.queuePendingRequest(stale2)
        appState.pendingRequests = SharedStorage.getPendingRequests()

        XCTAssertNil(appState.activeApprovalRequest)
        XCTAssertEqual(appState.pendingApprovalQueueDepth, 0)
    }

    func test_pendingApprovalQueueDepth_matchesFreshCount() {
        let stale = makeRequest(id: "stale", ageSeconds: 600)
        let f1 = makeRequest(id: "f1", ageSeconds: 30)
        let f2 = makeRequest(id: "f2", ageSeconds: 60)
        let f3 = makeRequest(id: "f3", ageSeconds: 120)
        SharedStorage.queuePendingRequest(stale)
        SharedStorage.queuePendingRequest(f1)
        SharedStorage.queuePendingRequest(f2)
        SharedStorage.queuePendingRequest(f3)
        appState.pendingRequests = SharedStorage.getPendingRequests()

        XCTAssertEqual(appState.pendingApprovalQueueDepth, 3,
                       "Depth should count only fresh requests, ignoring the stale one")
    }

    // MARK: - purgeStalePendingRequests

    func test_purgeStalePendingRequests_removesStaleRows() {
        let fresh = makeRequest(id: "fresh", ageSeconds: 30)
        let stale = makeRequest(id: "stale", ageSeconds: 600)
        SharedStorage.queuePendingRequest(fresh)
        SharedStorage.queuePendingRequest(stale)

        appState.purgeStalePendingRequests()

        let remaining = SharedStorage.getPendingRequests().map { $0.id }
        XCTAssertEqual(remaining, ["fresh"], "Stale request must be removed from on-disk storage")
    }

    func test_purgeStalePendingRequests_writesExpiredActivityEntry() {
        let stale = makeRequest(id: "stale", ageSeconds: 700, kind: 30023)
        SharedStorage.queuePendingRequest(stale)

        appState.purgeStalePendingRequests()

        let log = SharedStorage.getActivityLog()
        XCTAssertEqual(log.count, 1, "An expired ActivityEntry should be logged for the purged row")
        let entry = log[0]
        XCTAssertEqual(entry.status, "expired")
        XCTAssertEqual(entry.method, "sign_event")
        XCTAssertEqual(entry.eventKind, 30023)
        XCTAssertEqual(entry.clientPubkey, testClient)
        XCTAssertEqual(entry.signerPubkeyHex, testSigner)
        XCTAssertNotNil(entry.errorMessage)
    }

    func test_purgeStalePendingRequests_isIdempotent() {
        // Empty start — purge should be a no-op.
        appState.purgeStalePendingRequests()
        XCTAssertEqual(SharedStorage.getActivityLog().count, 0,
                       "Purge with no stale rows must not log anything")

        // Add a fresh row — purge should still be a no-op.
        let fresh = makeRequest(id: "fresh", ageSeconds: 30)
        SharedStorage.queuePendingRequest(fresh)
        appState.purgeStalePendingRequests()
        XCTAssertEqual(SharedStorage.getActivityLog().count, 0,
                       "Purge with only fresh rows must not log anything")
        XCTAssertEqual(SharedStorage.getPendingRequests().count, 1,
                       "Fresh row must remain after no-op purge")

        // Run purge twice on a stale row — second call is a no-op.
        let stale = makeRequest(id: "stale", ageSeconds: 600)
        SharedStorage.queuePendingRequest(stale)
        appState.purgeStalePendingRequests()
        XCTAssertEqual(SharedStorage.getActivityLog().count, 1)
        appState.purgeStalePendingRequests()
        XCTAssertEqual(SharedStorage.getActivityLog().count, 1,
                       "Second purge with no stale rows must not log a second expired entry")
    }

    // MARK: - refreshPendingRequests is read-only (no purge)

    func test_refreshPendingRequests_doesNotPurge() {
        // refreshPendingRequests is observer-driven (fires on every
        // .pendingRequestsUpdated post, including during legacy backfill
        // migrations that re-write rows with sentinel timestamps).
        // Stale-row eviction is decoupled to explicit user-active
        // triggers (MainTabView scenePhase .active) — `freshPendingRequests`
        // computed surface filters at read time, so the UI stays clean
        // even if storage briefly contains stale rows.
        let fresh = makeRequest(id: "fresh", ageSeconds: 30)
        let stale = makeRequest(id: "stale", ageSeconds: 600)
        SharedStorage.queuePendingRequest(fresh)
        SharedStorage.queuePendingRequest(stale)

        appState.refreshPendingRequests()

        XCTAssertEqual(
            Set(appState.pendingRequests.map { $0.id }),
            ["fresh", "stale"],
            "refreshPendingRequests is read-only — does NOT purge stale rows"
        )
        XCTAssertEqual(
            appState.freshPendingRequests.map { $0.id },
            ["fresh"],
            "freshPendingRequests filters at read time so the UI never shows stale"
        )
        XCTAssertEqual(
            SharedStorage.getActivityLog().count, 0,
            "No expired ActivityEntry should be written by refreshPendingRequests alone"
        )
    }

    // MARK: - setKindOverride

    func test_setKindOverride_writesToClientPermissions() {
        // Seed a permissions row first — setKindOverride is a no-op when
        // the row doesn't exist (caller's contract: client is paired).
        let now = Date().timeIntervalSince1970
        let perms = ClientPermissions(
            pubkey: testClient,
            trustLevel: .medium,
            kindOverrides: [:],
            methodPermissions: [],
            connectedAt: now,
            lastSeen: now,
            requestCount: 0,
            signerPubkeyHex: testSigner
        )
        SharedStorage.saveClientPermissions(perms)

        appState.setKindOverride(signer: testSigner, client: testClient, kind: 1, allowed: true)

        let updated = SharedStorage.getClientPermissions(signer: testSigner, client: testClient)
        XCTAssertEqual(updated?.kindOverrides[1], true,
                       "setKindOverride must write the override to the matching (signer, client) row")
    }

    func test_setKindOverride_isNoOpWithoutPermissionsRow() {
        // No row seeded. setKindOverride should silently no-op rather
        // than create one — clients must be paired through the normal
        // approval flow before per-kind overrides apply.
        appState.setKindOverride(signer: testSigner, client: testClient, kind: 1, allowed: true)

        XCTAssertNil(SharedStorage.getClientPermissions(signer: testSigner, client: testClient))
    }
}
