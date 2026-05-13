import XCTest
@testable import Clave

final class PairAccountCapInfoTests: XCTestCase {

    func testBelowCap() {
        let info = PairAccountCapInfo(signerPubkey: "pk1", currentPairCount: 2)
        XCTAssertFalse(info.isAtCap)
        XCTAssertEqual(info.remaining, 3)
    }

    func testAtCap() {
        let info = PairAccountCapInfo(signerPubkey: "pk1", currentPairCount: 5)
        XCTAssertTrue(info.isAtCap)
        XCTAssertEqual(info.remaining, 0)
    }

    func testAboveCap() {
        // Defensive: if storage somehow contains 6+ pairs (race, bug, manual
        // edit), treat as capped — never negative remaining.
        let info = PairAccountCapInfo(signerPubkey: "pk1", currentPairCount: 7)
        XCTAssertTrue(info.isAtCap)
        XCTAssertEqual(info.remaining, 0)
    }

    func testCapConstant() {
        // Cap is the single source of truth — matches the proxy's
        // pair-client enforcement (5 pairs/signer per the Phase 1
        // multi-account sprint).
        XCTAssertEqual(PairAccountCapInfo.cap, 5)
    }
}
