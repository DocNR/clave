import XCTest
@testable import Clave

final class HandshakeResultTests: XCTestCase {

    func testEmptyResult() {
        let r = HandshakeResult(succeeded: [], failed: [])
        XCTAssertEqual(r.succeeded.count, 0)
        XCTAssertEqual(r.failed.count, 0)
        XCTAssertFalse(r.isPartialFailure)
        XCTAssertFalse(r.isAllSuccess)
        XCTAssertFalse(r.isAllFailure)
    }

    func testAllSuccess() {
        let r = HandshakeResult(succeeded: ["pk1", "pk2"], failed: [])
        XCTAssertTrue(r.isAllSuccess)
        XCTAssertFalse(r.isPartialFailure)
        XCTAssertFalse(r.isAllFailure)
    }

    func testPartialFailure() {
        let r = HandshakeResult(
            succeeded: ["pk1"],
            failed: [HandshakeResult.FailedSigner(signerPubkey: "pk2", errorMessage: "cap exceeded")]
        )
        XCTAssertFalse(r.isAllSuccess)
        XCTAssertTrue(r.isPartialFailure)
        XCTAssertFalse(r.isAllFailure)
    }

    func testAllFailure() {
        let r = HandshakeResult(
            succeeded: [],
            failed: [
                HandshakeResult.FailedSigner(signerPubkey: "pk1", errorMessage: "relay down"),
                HandshakeResult.FailedSigner(signerPubkey: "pk2", errorMessage: "relay down")
            ]
        )
        XCTAssertFalse(r.isAllSuccess)
        XCTAssertFalse(r.isPartialFailure)
        XCTAssertTrue(r.isAllFailure)
    }
}
