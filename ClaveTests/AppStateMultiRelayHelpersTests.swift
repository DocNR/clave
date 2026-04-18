import XCTest
@testable import Clave

final class AppStateMultiRelayHelpersTests: XCTestCase {

    func testConnectToRelaysReturnsEmptyForEmptyInput() async {
        let appState = AppState()
        let result = await appState._testOnlyConnectToRelays(urls: [], timeout: 1.0)
        XCTAssertEqual(result.count, 0)
    }

    func testConnectToRelaysSkipsUnreachableURLs() async {
        let appState = AppState()
        let result = await appState._testOnlyConnectToRelays(
            urls: ["wss://127.0.0.1:1", "wss://not-a-real-relay.invalid.test"],
            timeout: 1.5
        )
        XCTAssertEqual(result.count, 0)
    }

    func testPublishEventToRelaysReturnsZeroForEmptyInput() async {
        let appState = AppState()
        let count = await appState._testOnlyPublishEventToRelays([], event: ["kind": 1])
        XCTAssertEqual(count, 0)
    }

    func testFetchEventsFromRelaysReturnsEmptyForEmptyInput() async {
        let appState = AppState()
        let events = await appState._testOnlyFetchEventsFromRelays([], filter: [:], timeout: 1.0)
        XCTAssertEqual(events.count, 0)
    }
}
