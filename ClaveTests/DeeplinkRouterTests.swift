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

    // Zero accounts + valid URI → .stashForOnboarding(parsed) (Sign in with
    // Clave: a brand-new user deep-linked from a partner must have the connect
    // URI stashed through onboarding, not dropped — replaces the old .ignore).
    func testNostrconnect_zeroAccounts_routesToStashForOnboarding() throws {
        let validURI = "nostrconnect://abc123def456abc123def456abc123def456abc123def456abc123def456abcd?relay=wss%3A%2F%2Frelay.example.com&secret=topsecret"
        let url = URL(string: validURI)!
        let result = DeeplinkRouter.route(url: url, accountCount: 0)
        guard case .stashForOnboarding(let parsed) = result else {
            return XCTFail("Expected .stashForOnboarding, got \(result)")
        }
        XCTAssertEqual(parsed.clientPubkey, "abc123def456abc123def456abc123def456abc123def456abc123def456abcd")
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

    /// HTTPS URL on a non-clave.casa host → routes to .ignore.
    /// (Phase B added the `https` scheme branch; the host guard rejects
    /// any host other than `clave.casa` so external HTTPS URLs can't
    /// inadvertently trigger Clave routing.)
    func testHTTPS_nonClaveCasaHost_routesToIgnore() throws {
        let url = URL(string: "https://example.com/foo")!
        let result = DeeplinkRouter.route(url: url, accountCount: 1)
        guard case .ignore = result else {
            return XCTFail("Expected .ignore for non-clave.casa host, got \(result)")
        }
    }

    // MARK: - Universal Links (https://clave.casa/connect/?uri=...)

    /// Valid Universal Link with single account → routes to .approve(parsedURI).
    /// Encoded nostrconnect URI must be in the `uri` query parameter.
    func testUniversalLink_singleAccount_routesToApprove() throws {
        let nostrconnect = "nostrconnect://abc123def456abc123def456abc123def456abc123def456abc123def456abcd?relay=wss%3A%2F%2Frelay.example.com&secret=topsecret"
        // Must exclude ?&=# from allowed set so they get percent-encoded and
        // don't fragment the outer URL's query string.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "?&=#")
        let encoded = nostrconnect.addingPercentEncoding(withAllowedCharacters: allowed)!
        let url = URL(string: "https://clave.casa/connect/?uri=\(encoded)")!
        let result = DeeplinkRouter.route(url: url, accountCount: 1)
        guard case .approve(let parsed) = result else {
            return XCTFail("Expected .approve, got \(result)")
        }
        XCTAssertEqual(parsed.clientPubkey, "abc123def456abc123def456abc123def456abc123def456abc123def456abcd")
    }

    /// Universal Link with multi-account → routes to .pickAccount.
    func testUniversalLink_multiAccount_routesToPickAccount() throws {
        let nostrconnect = "nostrconnect://abc123def456abc123def456abc123def456abc123def456abc123def456abcd?relay=wss%3A%2F%2Frelay.example.com&secret=topsecret"
        // Must exclude ?&=# from allowed set so they get percent-encoded and
        // don't fragment the outer URL's query string.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "?&=#")
        let encoded = nostrconnect.addingPercentEncoding(withAllowedCharacters: allowed)!
        let url = URL(string: "https://clave.casa/connect/?uri=\(encoded)")!
        let result = DeeplinkRouter.route(url: url, accountCount: 3)
        guard case .pickAccount = result else {
            return XCTFail("Expected .pickAccount, got \(result)")
        }
    }

    /// Universal Link without `uri` query param → routes to .ignore.
    func testUniversalLink_missingURIParam_routesToIgnore() throws {
        let url = URL(string: "https://clave.casa/connect/")!
        let result = DeeplinkRouter.route(url: url, accountCount: 1)
        guard case .ignore = result else {
            return XCTFail("Expected .ignore, got \(result)")
        }
    }

    /// Universal Link with present-but-empty `uri` value → routes to .ignore.
    /// Distinct code path from missing param: queryItems returns "" not nil.
    /// The router's `!uriParam.isEmpty` guard catches this.
    func testUniversalLink_emptyURIValue_routesToIgnore() throws {
        let url = URL(string: "https://clave.casa/connect/?uri=")!
        let result = DeeplinkRouter.route(url: url, accountCount: 1)
        guard case .ignore = result else {
            return XCTFail("Expected .ignore, got \(result)")
        }
    }

    /// Universal Link with malformed `uri` value → routes to .ignore.
    func testUniversalLink_malformedURI_routesToIgnore() throws {
        let url = URL(string: "https://clave.casa/connect/?uri=garbage-not-a-nostrconnect-uri")!
        let result = DeeplinkRouter.route(url: url, accountCount: 1)
        guard case .ignore = result else {
            return XCTFail("Expected .ignore, got \(result)")
        }
    }

    /// HTTPS URL on clave.casa but NOT /connect/ path → routes to .ignore.
    /// AASA scopes Universal Links to /connect/ ONLY; /edit and / must
    /// always go to Safari/clave.casa, never to Clave iOS.
    func testUniversalLink_wrongPath_routesToIgnore() throws {
        let editURL = URL(string: "https://clave.casa/edit#bunker=anything")!
        let landingURL = URL(string: "https://clave.casa/")!
        XCTAssertEqual(DeeplinkRouter.route(url: editURL, accountCount: 1), .ignore)
        XCTAssertEqual(DeeplinkRouter.route(url: landingURL, accountCount: 1), .ignore)
    }

    /// Universal Link with zero accounts + valid URI → .stashForOnboarding.
    /// The brand-new-user Conduit path: the URI survives into onboarding
    /// instead of being dropped.
    func testUniversalLink_zeroAccounts_routesToStashForOnboarding() throws {
        let url = URL(string: "https://clave.casa/connect/?uri=\(Self.encodedNostrconnect)")!
        let result = DeeplinkRouter.route(url: url, accountCount: 0)
        guard case .stashForOnboarding(let parsed) = result else {
            return XCTFail("Expected .stashForOnboarding, got \(result)")
        }
        XCTAssertEqual(parsed.clientPubkey, Self.sampleClientPubkey)
    }

    // MARK: - clave://connect?uri=... (reserved scheme, first handler)

    /// clave://connect?uri= with single account → .approve — byte-identical
    /// routing to the nostrconnect:// and Universal Link forms.
    func testClaveConnect_singleAccount_routesToApprove() throws {
        let url = URL(string: "clave://connect?uri=\(Self.encodedNostrconnect)")!
        let result = DeeplinkRouter.route(url: url, accountCount: 1)
        guard case .approve(let parsed) = result else {
            return XCTFail("Expected .approve, got \(result)")
        }
        XCTAssertEqual(parsed.clientPubkey, Self.sampleClientPubkey)
    }

    /// clave://connect?uri= with multiple accounts → .pickAccount.
    func testClaveConnect_multiAccount_routesToPickAccount() throws {
        let url = URL(string: "clave://connect?uri=\(Self.encodedNostrconnect)")!
        let result = DeeplinkRouter.route(url: url, accountCount: 3)
        guard case .pickAccount = result else {
            return XCTFail("Expected .pickAccount, got \(result)")
        }
    }

    /// clave://connect?uri= with zero accounts → .stashForOnboarding.
    func testClaveConnect_zeroAccounts_routesToStashForOnboarding() throws {
        let url = URL(string: "clave://connect?uri=\(Self.encodedNostrconnect)")!
        let result = DeeplinkRouter.route(url: url, accountCount: 0)
        guard case .stashForOnboarding(let parsed) = result else {
            return XCTFail("Expected .stashForOnboarding, got \(result)")
        }
        XCTAssertEqual(parsed.clientPubkey, Self.sampleClientPubkey)
    }

    /// clave:// with a host other than `connect` → .ignore, even with a uri
    /// param. The reserved scheme handles ONLY connect?uri= for now.
    func testClaveScheme_nonConnectHost_routesToIgnore() throws {
        let url = URL(string: "clave://settings?uri=\(Self.encodedNostrconnect)")!
        let result = DeeplinkRouter.route(url: url, accountCount: 1)
        guard case .ignore = result else {
            return XCTFail("Expected .ignore for non-connect clave host, got \(result)")
        }
    }

    /// clave://connect with no uri param → .ignore.
    func testClaveConnect_missingURIParam_routesToIgnore() throws {
        let url = URL(string: "clave://connect")!
        let result = DeeplinkRouter.route(url: url, accountCount: 1)
        guard case .ignore = result else {
            return XCTFail("Expected .ignore, got \(result)")
        }
    }

    /// clave://connect?uri= with present-but-empty value → .ignore.
    func testClaveConnect_emptyURIValue_routesToIgnore() throws {
        let url = URL(string: "clave://connect?uri=")!
        let result = DeeplinkRouter.route(url: url, accountCount: 1)
        guard case .ignore = result else {
            return XCTFail("Expected .ignore, got \(result)")
        }
    }

    /// clave://connect?uri= with a malformed inner URI → .ignore, at every
    /// account count (parse failure dominates the account-count branch).
    func testClaveConnect_malformedURI_routesToIgnore() throws {
        let url = URL(string: "clave://connect?uri=garbage-not-a-nostrconnect-uri")!
        for count in [0, 1, 3] {
            let result = DeeplinkRouter.route(url: url, accountCount: count)
            guard case .ignore = result else {
                return XCTFail("Expected .ignore at accountCount=\(count), got \(result)")
            }
        }
    }

    // MARK: - Fixtures

    private static let sampleClientPubkey =
        "abc123def456abc123def456abc123def456abc123def456abc123def456abcd"

    /// A valid `nostrconnect://` URI, percent-encoded for embedding in the
    /// `uri` query parameter of a Universal Link or clave://connect URL.
    private static let encodedNostrconnect: String = {
        let nostrconnect =
            "nostrconnect://\(sampleClientPubkey)?relay=wss%3A%2F%2Frelay.example.com&secret=topsecret"
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "?&=#")
        return nostrconnect.addingPercentEncoding(withAllowedCharacters: allowed)!
    }()
}
