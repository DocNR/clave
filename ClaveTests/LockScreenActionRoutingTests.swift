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
}
