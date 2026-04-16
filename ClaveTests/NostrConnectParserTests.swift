import XCTest
@testable import Clave

final class NostrConnectParserTests: XCTestCase {

    func testParseValidURI() throws {
        let uri = "nostrconnect://83f3b2ae6aa368e8275397b9c26cf550101d63ebaab900d19dd4a4429f5ad8f5?relay=wss%3A%2F%2Frelay1.example.com&secret=abc123&name=TestClient&url=https%3A%2F%2Ftest.com&image=https%3A%2F%2Ftest.com%2Ficon.png"
        let result = try NostrConnectParser.parse(uri)
        XCTAssertEqual(result.clientPubkey, "83f3b2ae6aa368e8275397b9c26cf550101d63ebaab900d19dd4a4429f5ad8f5")
        XCTAssertEqual(result.relays, ["wss://relay1.example.com"])
        XCTAssertEqual(result.secret, "abc123")
        XCTAssertEqual(result.name, "TestClient")
        XCTAssertEqual(result.url, "https://test.com")
        XCTAssertEqual(result.imageURL, "https://test.com/icon.png")
    }

    func testParseMultipleRelays() throws {
        let uri = "nostrconnect://aabbccdd?relay=wss%3A%2F%2Frelay1.com&relay=wss%3A%2F%2Frelay2.com&secret=xyz"
        let result = try NostrConnectParser.parse(uri)
        XCTAssertEqual(result.relays.count, 2)
        XCTAssertTrue(result.relays.contains("wss://relay1.com"))
        XCTAssertTrue(result.relays.contains("wss://relay2.com"))
    }

    func testParsePermsParam() throws {
        let uri = "nostrconnect://aabbccdd?relay=wss%3A%2F%2Frelay.com&secret=s&perms=sign_event%3A1%2Csign_event%3A1301%2Cnip44_encrypt"
        let result = try NostrConnectParser.parse(uri)
        XCTAssertEqual(result.requestedPerms, ["sign_event:1", "sign_event:1301", "nip44_encrypt"])
    }

    func testParseMissingSecretThrows() {
        let uri = "nostrconnect://aabbccdd?relay=wss%3A%2F%2Frelay.com"
        XCTAssertThrowsError(try NostrConnectParser.parse(uri)) { error in
            XCTAssertEqual(error as? NostrConnectParser.ParseError, .missingSecret)
        }
    }

    func testParseMissingRelayThrows() {
        let uri = "nostrconnect://aabbccdd?secret=abc"
        XCTAssertThrowsError(try NostrConnectParser.parse(uri)) { error in
            XCTAssertEqual(error as? NostrConnectParser.ParseError, .missingRelay)
        }
    }

    func testParseInvalidSchemeThrows() {
        let uri = "bunker://aabbccdd?relay=wss%3A%2F%2Frelay.com&secret=abc"
        XCTAssertThrowsError(try NostrConnectParser.parse(uri)) { error in
            XCTAssertEqual(error as? NostrConnectParser.ParseError, .invalidScheme)
        }
    }

    func testSuggestedTrustLevel_noPerms() throws {
        let uri = "nostrconnect://aabbccdd?relay=wss%3A%2F%2Frelay.com&secret=s"
        let result = try NostrConnectParser.parse(uri)
        XCTAssertEqual(result.suggestedTrustLevel, .medium)
    }

    func testSuggestedTrustLevel_narrowPerms() throws {
        let uri = "nostrconnect://aabbccdd?relay=wss%3A%2F%2Frelay.com&secret=s&perms=sign_event%3A1"
        let result = try NostrConnectParser.parse(uri)
        XCTAssertEqual(result.suggestedTrustLevel, .low)
    }
}
