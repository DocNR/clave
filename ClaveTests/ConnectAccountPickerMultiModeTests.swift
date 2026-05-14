import XCTest
@testable import Clave

/// Pure-logic tests for ConnectAccountPicker .multi mode behavior. UI
/// rendering is verified in a manual smoke test (a SwiftUI render in a
/// unit-test target requires extra plumbing; the logic helpers are pure
/// and easier to assert directly).
final class ConnectAccountPickerMultiModeTests: XCTestCase {

    func testDefaultSelection_5OrFewer_AllChecked() {
        let pubkeys = ["pk1", "pk2", "pk3", "pk4", "pk5"]
        let selected = ConnectAccountPicker.defaultSelection(
            for: pubkeys,
            cappedSigners: Set()
        )
        XCTAssertEqual(selected, Set(pubkeys))
    }

    func testDefaultSelection_MoreThan5_NoneChecked() {
        let pubkeys = ["pk1", "pk2", "pk3", "pk4", "pk5", "pk6"]
        let selected = ConnectAccountPicker.defaultSelection(
            for: pubkeys,
            cappedSigners: Set()
        )
        XCTAssertEqual(selected, Set())
    }

    func testDefaultSelection_5OrFewer_CappedExcluded() {
        let pubkeys = ["pk1", "pk2", "pk3"]
        let selected = ConnectAccountPicker.defaultSelection(
            for: pubkeys,
            cappedSigners: ["pk2"]
        )
        XCTAssertEqual(selected, Set(["pk1", "pk3"]))
    }

    func testDefaultSelection_MoreThan5_CappedExcluded() {
        let pubkeys = ["pk1", "pk2", "pk3", "pk4", "pk5", "pk6"]
        let selected = ConnectAccountPicker.defaultSelection(
            for: pubkeys,
            cappedSigners: ["pk3"]
        )
        XCTAssertEqual(selected, Set())
    }

    func testCanProceed_RequiresAtLeastOneSelected() {
        XCTAssertFalse(ConnectAccountPicker.canProceed(selectedCount: 0))
        XCTAssertTrue(ConnectAccountPicker.canProceed(selectedCount: 1))
        XCTAssertTrue(ConnectAccountPicker.canProceed(selectedCount: 5))
    }

    func testDefaultSelection_AllCapped_EmptyResult() {
        // Boundary: ≤5 accounts, but EVERY pubkey is in cappedSigners → empty
        // selection. Picker presents but Continue stays disabled until user
        // unchecks nothing (i.e. they can't proceed without revoking a pair
        // elsewhere first). Locks the cap + default-selection interaction.
        let pubkeys = ["pk1", "pk2", "pk3"]
        let selected = ConnectAccountPicker.defaultSelection(
            for: pubkeys,
            cappedSigners: ["pk1", "pk2", "pk3"]
        )
        XCTAssertEqual(selected, Set())
    }
}
