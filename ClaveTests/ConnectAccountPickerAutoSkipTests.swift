import XCTest
@testable import Clave

/// The auto-skip rule is a static predicate so it can be checked at the
/// presenter level (parent view decides whether to present the picker at
/// all). Tests verify the predicate directly.
final class ConnectAccountPickerAutoSkipTests: XCTestCase {

    func testShouldSkipWhenSingleAccount() {
        XCTAssertTrue(ConnectAccountPicker.shouldAutoSkip(accountCount: 1))
    }

    func testShouldNotSkipWhenMultipleAccounts() {
        XCTAssertFalse(ConnectAccountPicker.shouldAutoSkip(accountCount: 2))
        XCTAssertFalse(ConnectAccountPicker.shouldAutoSkip(accountCount: 5))
    }

    func testShouldNotSkipWhenZeroAccounts() {
        // Edge case: zero accounts means no picker target. Caller should
        // route to onboarding; picker should NOT skip and auto-bind (there's
        // nothing to bind to).
        XCTAssertFalse(ConnectAccountPicker.shouldAutoSkip(accountCount: 0))
    }
}
