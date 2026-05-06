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

    // MARK: - dismissActiveAlert (root alert "Not now" handling)
    //
    // Build 54 added a root .alert that auto-presents whenever
    // activeApprovalRequest != nil. With a no-op binding setter, system-
    // driven dismissals (navigation, backgrounding, deep-link interrupt)
    // caused the alert to infinite-loop on every view re-evaluation.
    // build 56 fix: dismissActiveAlert() adds the active request id to an
    // in-memory dismissed set; activeApprovalRequest filters those out.
    // Bell badge / inbox sheet still surface the request — "Not now" means
    // *handle via the bell*, not *throw away*.

    func test_dismissActiveAlert_skipsToNextUndismissedRequest() {
        let r1 = makeRequest(id: "r1", ageSeconds: 60)
        let r2 = makeRequest(id: "r2", ageSeconds: 30)
        SharedStorage.queuePendingRequest(r1)
        SharedStorage.queuePendingRequest(r2)
        appState.refreshPendingRequests()

        XCTAssertEqual(appState.activeApprovalRequest?.id, "r1",
                       "FIFO queue: oldest fresh request first")

        appState.dismissActiveAlert()

        XCTAssertEqual(appState.activeApprovalRequest?.id, "r2",
                       "After dismiss, next undismissed fresh request becomes active")

        appState.dismissActiveAlert()

        XCTAssertNil(appState.activeApprovalRequest,
                     "All fresh requests dismissed → no active request → alert stays closed")
    }

    func test_dismissActiveAlert_doesNotAffectQueueDepth() {
        // The bell badge counts ALL fresh pending requests, dismissed-from-
        // alert or not. Dismissing the alert does NOT reduce the queue —
        // the user is just routing handling through the bell instead.
        let r1 = makeRequest(id: "r1", ageSeconds: 30)
        let r2 = makeRequest(id: "r2", ageSeconds: 60)
        SharedStorage.queuePendingRequest(r1)
        SharedStorage.queuePendingRequest(r2)
        appState.refreshPendingRequests()

        XCTAssertEqual(appState.pendingApprovalQueueDepth, 2)

        appState.dismissActiveAlert()
        appState.dismissActiveAlert()

        XCTAssertEqual(appState.pendingApprovalQueueDepth, 2,
                       "Queue depth unchanged — dismissed requests still in inbox")
        XCTAssertEqual(appState.freshPendingRequests.count, 2,
                       "Fresh queue unchanged — dismissed requests still in fresh list")
    }

    func test_dismissActiveAlert_isNoOpWhenNoActiveRequest() {
        XCTAssertNil(appState.activeApprovalRequest)

        appState.dismissActiveAlert()  // must not crash on empty state
        appState.dismissActiveAlert()

        XCTAssertNil(appState.activeApprovalRequest)
    }

    func test_newRequestAfterDismissal_stillTriggersAlert() {
        // Critical UX guarantee: dismissing one alert must NOT suppress
        // alerts for future requests. Each new request id gets its own
        // alert opportunity.
        let r1 = makeRequest(id: "r1", ageSeconds: 30)
        SharedStorage.queuePendingRequest(r1)
        appState.refreshPendingRequests()
        appState.dismissActiveAlert()
        XCTAssertNil(appState.activeApprovalRequest)

        let r2 = makeRequest(id: "r2", ageSeconds: 0)
        SharedStorage.queuePendingRequest(r2)
        appState.refreshPendingRequests()

        XCTAssertEqual(appState.activeApprovalRequest?.id, "r2",
                       "New request id not in dismissed set → alert re-arms for it")
    }

    // MARK: - dismissAllActiveAlerts (root alert "Not now" handling)
    //
    // Build 57+ "Not now" button calls dismissAllActiveAlerts to escape
    // the entire alert batch in one tap, not just the active request.
    // Per-request dismissal would auto-chain to the next request — the
    // exact "alert keeps popping back up" behavior the button is supposed
    // to suppress. Approve and Deny remain per-request (they're
    // decisions, not deferrals); the bell badge / inbox still surface
    // every dismissed-but-still-pending request.

    func test_dismissAllActiveAlerts_silencesAllFreshRequests() {
        let r1 = makeRequest(id: "r1", ageSeconds: 30)
        let r2 = makeRequest(id: "r2", ageSeconds: 60)
        let r3 = makeRequest(id: "r3", ageSeconds: 90)
        SharedStorage.queuePendingRequest(r1)
        SharedStorage.queuePendingRequest(r2)
        SharedStorage.queuePendingRequest(r3)
        appState.refreshPendingRequests()

        XCTAssertNotNil(appState.activeApprovalRequest)
        XCTAssertEqual(appState.pendingApprovalQueueDepth, 3)

        appState.dismissAllActiveAlerts()

        XCTAssertNil(appState.activeApprovalRequest,
                     "All fresh requests dismissed → alert stays closed")
        XCTAssertEqual(appState.pendingApprovalQueueDepth, 3,
                       "Bell badge unchanged — requests still in inbox")
    }

    func test_dismissAllActiveAlerts_isNoOpWhenEmpty() {
        XCTAssertEqual(appState.freshPendingRequests.count, 0)

        appState.dismissAllActiveAlerts()  // must not crash on empty state

        XCTAssertNil(appState.activeApprovalRequest)
    }

    func test_dismissAllActiveAlerts_doesNotSilenceFutureRequests() {
        let r1 = makeRequest(id: "r1", ageSeconds: 30)
        let r2 = makeRequest(id: "r2", ageSeconds: 60)
        SharedStorage.queuePendingRequest(r1)
        SharedStorage.queuePendingRequest(r2)
        appState.refreshPendingRequests()

        appState.dismissAllActiveAlerts()
        XCTAssertNil(appState.activeApprovalRequest)

        // New request arrives after dismiss-all — its id isn't in the
        // dismissed set, so the alert MUST re-arm. This is the critical
        // guarantee that prevents "Not now" from silencing the app
        // permanently.
        let r3 = makeRequest(id: "r3", ageSeconds: 0)
        SharedStorage.queuePendingRequest(r3)
        appState.refreshPendingRequests()

        XCTAssertEqual(appState.activeApprovalRequest?.id, "r3",
                       "New request after dismiss-all must re-arm the alert")
    }

    // MARK: - Chain position (alert title "X of N" tracking)
    //
    // The root alert's title shows position-in-chain. Pre-build-59 the
    // format was "1 of <queueDepth>" using *remaining* count, so a chain
    // of 3 went 1-of-3 → 1-of-2 → 1-of-1. Build 59+ tracks
    // processedInChain so it goes 1-of-3 → 2-of-3 → 3-of-3, with
    // chainTotal expanding if new requests arrive mid-chain.

    func test_chainPosition_startsAtOneWithFreshChain() {
        let r1 = makeRequest(id: "r1", ageSeconds: 30)
        let r2 = makeRequest(id: "r2", ageSeconds: 60)
        let r3 = makeRequest(id: "r3", ageSeconds: 90)
        SharedStorage.queuePendingRequest(r1)
        SharedStorage.queuePendingRequest(r2)
        SharedStorage.queuePendingRequest(r3)
        appState.refreshPendingRequests()

        XCTAssertEqual(appState.chainPosition, 1, "Fresh chain starts at position 1")
        XCTAssertEqual(appState.chainTotal, 3, "Chain total matches fresh queue size")
    }

    func test_chainPosition_advancesThroughChain() async {
        // Wire up an account so performApprove can find a signing key.
        // Without this, performApprove returns .failedAndRemoved (which
        // also advances the chain) but for clarity we test the .signed
        // path. Actually .failedAndRemoved is fine for this test — the
        // chain advancement is what we're verifying, not the signing.
        let r1 = makeRequest(id: "r1", ageSeconds: 30)
        let r2 = makeRequest(id: "r2", ageSeconds: 60)
        let r3 = makeRequest(id: "r3", ageSeconds: 90)
        SharedStorage.queuePendingRequest(r1)
        SharedStorage.queuePendingRequest(r2)
        SharedStorage.queuePendingRequest(r3)
        appState.refreshPendingRequests()

        XCTAssertEqual(appState.chainPosition, 1)
        XCTAssertEqual(appState.chainTotal, 3)

        // Deny is synchronous and doesn't require Keychain — perfect for
        // exercising the chain-advancement path without the network round-
        // trip performApprove needs.
        guard let active1 = appState.activeApprovalRequest else {
            XCTFail("Expected r1 active"); return
        }
        appState.denyPendingRequest(active1)

        XCTAssertEqual(appState.chainPosition, 2, "After 1 deny: position is 2")
        XCTAssertEqual(appState.chainTotal, 3, "Total stays 3 (1 processed + 2 remaining)")

        guard let active2 = appState.activeApprovalRequest else {
            XCTFail("Expected r2 active"); return
        }
        appState.denyPendingRequest(active2)

        XCTAssertEqual(appState.chainPosition, 3, "After 2 denies: position is 3")
        XCTAssertEqual(appState.chainTotal, 3, "Total still 3")

        guard let active3 = appState.activeApprovalRequest else {
            XCTFail("Expected r3 active"); return
        }
        appState.denyPendingRequest(active3)

        // Chain ended — counter must reset for the next chain.
        XCTAssertNil(appState.activeApprovalRequest)
        XCTAssertEqual(appState.processedInChain, 0,
                       "Chain end must reset processedInChain so next chain starts at 1")
    }

    func test_chainTotal_bumpsWhenNewRequestArrivesMidChain() {
        let r1 = makeRequest(id: "r1", ageSeconds: 30)
        let r2 = makeRequest(id: "r2", ageSeconds: 60)
        SharedStorage.queuePendingRequest(r1)
        SharedStorage.queuePendingRequest(r2)
        appState.refreshPendingRequests()

        XCTAssertEqual(appState.chainTotal, 2)

        guard let active1 = appState.activeApprovalRequest else {
            XCTFail("Expected r1 active"); return
        }
        appState.denyPendingRequest(active1)

        XCTAssertEqual(appState.chainPosition, 2)
        XCTAssertEqual(appState.chainTotal, 2, "Two-pending chain at position 2")

        // R3 arrives mid-chain — chain total must bump to reflect the new
        // request without resetting our position.
        let r3 = makeRequest(id: "r3", ageSeconds: 0)
        SharedStorage.queuePendingRequest(r3)
        appState.refreshPendingRequests()

        XCTAssertEqual(appState.chainPosition, 2,
                       "Position unchanged — we're still on the second decision")
        XCTAssertEqual(appState.chainTotal, 3,
                       "Total bumps to 3: 1 processed + 2 remaining")
    }

    func test_dismissAllActiveAlerts_resetsChainCounter() {
        let r1 = makeRequest(id: "r1", ageSeconds: 30)
        let r2 = makeRequest(id: "r2", ageSeconds: 60)
        SharedStorage.queuePendingRequest(r1)
        SharedStorage.queuePendingRequest(r2)
        appState.refreshPendingRequests()

        // Advance through one to seed processedInChain.
        guard let active1 = appState.activeApprovalRequest else {
            XCTFail("Expected r1 active"); return
        }
        appState.denyPendingRequest(active1)
        XCTAssertEqual(appState.processedInChain, 1)

        appState.dismissAllActiveAlerts()
        XCTAssertEqual(appState.processedInChain, 0,
                       "Not now must reset chain counter so next chain is fresh")

        // New request arrives — fresh chain starts at "1 of 1".
        let r3 = makeRequest(id: "r3", ageSeconds: 0)
        SharedStorage.queuePendingRequest(r3)
        appState.refreshPendingRequests()

        XCTAssertEqual(appState.chainPosition, 1)
        XCTAssertEqual(appState.chainTotal, 1)
    }

    func test_chainCounter_resetsWhenChainEndsViaTTLPurge() {
        // Stack a chain, advance one, then have TTL purge wipe the rest.
        // The defensive reset in refreshPendingRequests catches this path
        // (purge calls SharedStorage.removePendingRequest which fires the
        // observer → refreshPendingRequests → no active → reset).
        let fresh = makeRequest(id: "fresh", ageSeconds: 30)
        let stale1 = makeRequest(id: "stale1", ageSeconds: 600)
        let stale2 = makeRequest(id: "stale2", ageSeconds: 700)
        SharedStorage.queuePendingRequest(stale1)
        SharedStorage.queuePendingRequest(stale2)
        SharedStorage.queuePendingRequest(fresh)
        appState.refreshPendingRequests()

        // Only `fresh` is in the chain (stale ones filtered out).
        XCTAssertEqual(appState.chainTotal, 1)

        appState.denyPendingRequest(fresh)
        XCTAssertNil(appState.activeApprovalRequest)
        XCTAssertEqual(appState.processedInChain, 0,
                       "Natural chain end resets counter")

        // TTL purge — should not affect counter (already 0) and should
        // not crash.
        appState.purgeStalePendingRequests()
        XCTAssertEqual(appState.processedInChain, 0)
    }
}
