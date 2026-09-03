import XCTest
@testable import Clave

final class NostrConnectParserMultiAccountTests: XCTestCase {

    private let pubkey = "83f3b2ae6aa368e8275397b9c26cf550101d63ebaab900d19dd4a4429f5ad8f5"

    func testAccountsMultiFlagDetected() throws {
        let uri = "nostrconnect://\(pubkey)?relay=wss%3A%2F%2Frelay.example.com&secret=s&accounts=multi"
        let parsed = try NostrConnectParser.parse(uri)
        XCTAssertTrue(parsed.isMultiAccount)
    }

    func testAccountsMultiFlagAbsent() throws {
        let uri = "nostrconnect://\(pubkey)?relay=wss%3A%2F%2Frelay.example.com&secret=s"
        let parsed = try NostrConnectParser.parse(uri)
        XCTAssertFalse(parsed.isMultiAccount)
    }

    func testAccountsParamWithDifferentValueIgnored() throws {
        // Only `accounts=multi` enables the flag. Other values (eg
        // `accounts=single`, `accounts=2`) parse to false — forward-compat
        // with any future scheme that overloads this query key.
        let uri = "nostrconnect://\(pubkey)?relay=wss%3A%2F%2Frelay.example.com&secret=s&accounts=single"
        let parsed = try NostrConnectParser.parse(uri)
        XCTAssertFalse(parsed.isMultiAccount)
    }

    func testAccountsMultiPreservesOtherFields() throws {
        let uri = "nostrconnect://\(pubkey)?relay=wss%3A%2F%2Frelay.example.com&secret=s&accounts=multi&name=Spectr&perms=sign_event%3A1"
        let parsed = try NostrConnectParser.parse(uri)
        XCTAssertTrue(parsed.isMultiAccount)
        XCTAssertEqual(parsed.name, "Spectr")
        XCTAssertEqual(parsed.requestedPerms, ["sign_event:1"])
    }
}
