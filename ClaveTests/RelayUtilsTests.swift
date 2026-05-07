import XCTest
@testable import Clave

final class RelayUtilsTests: XCTestCase {

    func testConnectToRelaysReturnsEmptyForEmptyInput() async {
        let result = await RelayUtils.connectToRelays(urls: [], timeout: 1.0)
        XCTAssertEqual(result.count, 0)
    }

    func testConnectToRelaysSkipsUnreachableURLs() async {
        let result = await RelayUtils.connectToRelays(
            urls: ["wss://127.0.0.1:1", "wss://not-a-real-relay.invalid.test"],
            timeout: 1.5
        )
        XCTAssertEqual(result.count, 0)
    }

    func testPublishEventToRelaysReturnsZeroForEmptyInput() async {
        let count = await RelayUtils.publishEventToRelays([], event: ["kind": 1])
        XCTAssertEqual(count, 0)
    }

    func testFetchEventsFromRelaysReturnsEmptyForEmptyInput() async {
        let events = await RelayUtils.fetchEventsFromRelays([], filter: [:], timeout: 1.0)
        XCTAssertEqual(events.count, 0)
    }
}
