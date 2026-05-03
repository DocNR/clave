import XCTest
@testable import Clave

final class DeeplinkRouterTests: XCTestCase {

    // Valid nostrconnect:// URL with single account → routes to .approve(parsedURI)
    func testNostrconnect_singleAccount_routesToApprove() throws {
        let validURI = "nostrconnect://abc123def456abc123def456abc123def456abc123def456abc123def456abcd?relay=wss%3A%2F%2Frelay.example.com&secret=topsecret&perms=sign_event%3A1"
        let url = URL(string: validURI)!
        let result = DeeplinkRouter.route(url: url, accountCount: 1)
        guard case .approve(let parsed) = result else {
            return XCTFail("Expected .approve, got \(result)")
        }
        XCTAssertEqual(parsed.clientPubkey, "abc123def456abc123def456abc123def456abc123def456abc123def456abcd")
    }

    // Valid nostrconnect:// URL with multiple accounts → routes to .pickAccount(parsedURI)
    func testNostrconnect_multiAccount_routesToPickAccount() throws {
        let validURI = "nostrconnect://abc123def456abc123def456abc123def456abc123def456abc123def456abcd?relay=wss%3A%2F%2Frelay.example.com&secret=topsecret"
        let url = URL(string: validURI)!
        let result = DeeplinkRouter.route(url: url, accountCount: 3)
        guard case .pickAccount = result else {
            return XCTFail("Expected .pickAccount, got \(result)")
        }
    }

    // Zero accounts → routes to .ignore (defensive — should never happen in practice)
    func testNostrconnect_zeroAccounts_routesToIgnore() throws {
        let validURI = "nostrconnect://abc123def456abc123def456abc123def456abc123def456abc123def456abcd?relay=wss%3A%2F%2Frelay.example.com&secret=topsecret"
        let url = URL(string: validURI)!
        let result = DeeplinkRouter.route(url: url, accountCount: 0)
        guard case .ignore = result else {
            return XCTFail("Expected .ignore, got \(result)")
        }
    }

    // Malformed nostrconnect:// URL → routes to .ignore
    func testNostrconnect_invalidURI_routesToIgnore() throws {
        let url = URL(string: "nostrconnect://garbage-no-relay")!
        let result = DeeplinkRouter.route(url: url, accountCount: 1)
        guard case .ignore = result else {
            return XCTFail("Expected .ignore for malformed URI, got \(result)")
        }
    }

    // clave:// URL → routes to .ignore (reserved namespace, no handlers yet)
    func testClaveScheme_anything_routesToIgnore() throws {
        let url = URL(string: "clave://anything?foo=bar")!
        let result = DeeplinkRouter.route(url: url, accountCount: 2)
        guard case .ignore = result else {
            return XCTFail("Expected .ignore for clave://, got \(result)")
        }
    }

    // Other scheme → routes to .ignore
    func testOtherScheme_routesToIgnore() throws {
        let url = URL(string: "https://example.com/foo")!
        let result = DeeplinkRouter.route(url: url, accountCount: 1)
        guard case .ignore = result else {
            return XCTFail("Expected .ignore for non-nostrconnect/clave scheme, got \(result)")
        }
    }
}
