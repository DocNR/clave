import XCTest
import UserNotifications
@testable import Clave

/// Verifies the plumbing for lock-screen Approve / Deny action buttons:
/// - `PendingApprovalCategory` identifier + action ids stay stable
///   (changing them silently would break existing scheduled banners)
/// - `PendingApprovalBanner.schedule` sets the category id and userInfo
///   so iOS renders the action buttons and AppState's observer can find
///   the request by id
///
/// The end-to-end action handling path (notification tap →
/// `userNotificationCenter(_:didReceive:)` → NotificationCenter post →
/// AppState observer → approve/deny) is exercised manually on device
/// against TestFlight; integration testing it in unit tests would
/// require mocking UNUserNotificationCenter, which Apple doesn't
/// expose.
final class LockScreenActionRoutingTests: XCTestCase {

    func test_pendingApprovalCategory_constantsAreStable() {
        // These string values are baked into category-registered banners
        // already in flight on user devices. Changing them would orphan
        // existing notifications (no actions would render). If you need
        // to change one, add a v2 category and migrate carefully.
        XCTAssertEqual(PendingApprovalCategory.identifier, "PENDING_SIGNING_REQUEST")
        XCTAssertEqual(PendingApprovalCategory.approveActionId, "APPROVE_SIGNING")
        XCTAssertEqual(PendingApprovalCategory.denyActionId, "DENY_SIGNING")
    }

    func test_pendingApprovalBanner_makeContent_setsCategoryAndUserInfo() {
        // Verify the content shape the system needs to render Approve/Deny
        // action buttons and the action handler needs to resolve the
        // request by id. We test the pure builder rather than going
        // through UNUserNotificationCenter to avoid flaky dependencies
        // on simulator notification authorization and delivery timing.
        let testRequestId = "test-\(UUID().uuidString)"
        let testClientPubkey = "33" + String(repeating: "0", count: 62)

        let content = PendingApprovalBanner.makeContent(
            requestId: testRequestId,
            clientPubkey: testClientPubkey,
            eventKind: 1
        )

        XCTAssertEqual(
            content.categoryIdentifier,
            PendingApprovalCategory.identifier,
            "Banner content must set the category id so iOS renders Approve/Deny actions"
        )
        let storedRequestId = content.userInfo["pendingRequestId"] as? String
        XCTAssertEqual(
            storedRequestId,
            testRequestId,
            "Banner content must embed the pending request id so the action handler can resolve it"
        )
        XCTAssertEqual(content.title, "Approve Signing Request")
        XCTAssertEqual(content.interruptionLevel, .active)
    }

    // MARK: - NSE-delivered banner cleanup (PendingApprovalBanner.clear extension)
    //
    // `clear(requestId:)` previously only removed locally-scheduled banners
    // (identifier prefix `"pending-approval-"`). NSE-delivered banners use
    // the APNs notification identifier (proxy-assigned), so the only stable
    // way to find them is by `categoryIdentifier` + `userInfo.pendingRequestId`.
    // These tests verify the pure matcher; the runtime async path is exercised
    // by manual on-device smoke (TTL purge with a follow request was the
    // motivating bug — banner stranded in NC after the request expired).

    func test_nseDeliveredIds_matchesCorrectRequestByCategoryAndUserInfo() {
        let requestId = "target-request-id"
        let delivered: [DeliveredNotificationSnapshot] = [
            // Match: NSE-delivered for the target request
            DeliveredNotificationSnapshot(
                identifier: "apns-event-1",
                title: "Approve Signing Request",
                body: "primal wants to sign Note",
                categoryIdentifier: PendingApprovalCategory.identifier,
                userInfo: ["pendingRequestId": requestId, "event_id": "abc"]
            ),
            // Same category but different request — must NOT match
            DeliveredNotificationSnapshot(
                identifier: "apns-event-2",
                title: "Approve Signing Request",
                body: "yakihonne wants to sign Reaction",
                categoryIdentifier: PendingApprovalCategory.identifier,
                userInfo: ["pendingRequestId": "different-request"]
            ),
            // Same userInfo but different category — must NOT match
            DeliveredNotificationSnapshot(
                identifier: "apns-event-3",
                title: "Approve Signing Request",
                body: "wrong category",
                categoryIdentifier: "OTHER_CATEGORY",
                userInfo: ["pendingRequestId": requestId]
            ),
            // Missing userInfo pendingRequestId — must NOT match
            DeliveredNotificationSnapshot(
                identifier: "apns-event-4",
                title: "Approve Signing Request",
                body: "no request id",
                categoryIdentifier: PendingApprovalCategory.identifier,
                userInfo: [:]
            ),
        ]

        let result = PendingApprovalBanner.nseDeliveredIds(forRequest: requestId, in: delivered)
        XCTAssertEqual(result, ["apns-event-1"])
    }

    func test_nseDeliveredIds_returnsEmptyWhenNoMatch() {
        let delivered: [DeliveredNotificationSnapshot] = [
            DeliveredNotificationSnapshot(
                identifier: "x",
                title: "y",
                body: "z",
                categoryIdentifier: PendingApprovalCategory.identifier,
                userInfo: ["pendingRequestId": "other"]
            )
        ]
        XCTAssertTrue(
            PendingApprovalBanner.nseDeliveredIds(forRequest: "missing", in: delivered).isEmpty
        )
    }

    func test_nseDeliveredIds_returnsEmptyForEmptyDelivered() {
        XCTAssertTrue(
            PendingApprovalBanner.nseDeliveredIds(forRequest: "anything", in: []).isEmpty
        )
    }

    // MARK: - Blank notification cleanup (NSE-side sweep at start of next wake)
    //
    // NSE's silent-success path leaves an empty-title-empty-body notification
    // in NC. Old NSE-self-cleanup-after-contentHandler was racy. This pure
    // filter feeds the new NSE-side sweep that runs at the start of each fresh
    // wake — race-free because the notifications it removes were committed by
    // earlier wakes (already in the system).

    func test_blankDeliveredIds_findsEmptyTitleAndBody() {
        let delivered: [DeliveredNotificationSnapshot] = [
            blankSnap(id: "blank-empty"),
            blankSnap(id: "blank-spaces", title: " ", body: " "),
            blankSnap(id: "blank-whitespace", title: "\n\t ", body: "\t\n"),
            blankSnap(id: "kept-title", title: "Approve Signing Request", body: ""),
            blankSnap(id: "kept-body", title: "", body: "Relay rejected"),
            blankSnap(id: "kept-both", title: "Signing Failed", body: "Bad sig"),
        ]

        let result = Set(PendingApprovalBanner.blankDeliveredIds(in: delivered))
        XCTAssertEqual(result, Set(["blank-empty", "blank-spaces", "blank-whitespace"]))
    }

    func test_blankDeliveredIds_returnsEmptyForNoBlanks() {
        let delivered = [
            blankSnap(id: "kept", title: "Approve Signing Request", body: "x")
        ]
        XCTAssertTrue(PendingApprovalBanner.blankDeliveredIds(in: delivered).isEmpty)
    }

    private func blankSnap(
        id: String,
        title: String = "",
        body: String = "",
        category: String = "",
        userInfo: [AnyHashable: Any] = [:]
    ) -> DeliveredNotificationSnapshot {
        DeliveredNotificationSnapshot(
            identifier: id,
            title: title,
            body: body,
            categoryIdentifier: category,
            userInfo: userInfo
        )
    }
}
