import XCTest
@testable import Clave

final class DeveloperSettingsTests: XCTestCase {

    func testTapGateUnlocksOnSeventhTap() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let timestamps = (0..<7).map { base.addingTimeInterval(TimeInterval($0) * 0.3) }
        XCTAssertTrue(DeveloperSettings.tapGateSatisfied(timestamps: timestamps, window: 3.0, required: 7))
    }

    func testTapGateRejectsSixTaps() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let timestamps = (0..<6).map { base.addingTimeInterval(TimeInterval($0) * 0.3) }
        XCTAssertFalse(DeveloperSettings.tapGateSatisfied(timestamps: timestamps, window: 3.0, required: 7))
    }

    func testTapGateRejectsSlowTaps() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        // 7 taps but spread over 10 seconds
        let timestamps = (0..<7).map { base.addingTimeInterval(TimeInterval($0) * 1.5) }
        XCTAssertFalse(DeveloperSettings.tapGateSatisfied(timestamps: timestamps, window: 3.0, required: 7))
    }

    func testTapGateUsesOnlyMostRecentTaps() {
        // Old taps followed by a fresh burst of 7 within window should unlock
        let oldBase = Date(timeIntervalSince1970: 1_000_000)
        let freshBase = Date(timeIntervalSince1970: 1_000_100)
        let oldTaps = (0..<3).map { oldBase.addingTimeInterval(TimeInterval($0)) }
        let freshTaps = (0..<7).map { freshBase.addingTimeInterval(TimeInterval($0) * 0.3) }
        XCTAssertTrue(DeveloperSettings.tapGateSatisfied(timestamps: oldTaps + freshTaps, window: 3.0, required: 7))
    }
}
