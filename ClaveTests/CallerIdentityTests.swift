import XCTest
@testable import Clave

/// Rules behind the domain-first caller rendering shared by ApprovalSheet and
/// the onboarding caller banner (Sign in with Clave spec, "Domain-first
/// ApprovalSheet rendering"): what gets to be the big line, and how the
/// client-pubkey fingerprint is shaped.
final class CallerIdentityTests: XCTestCase {

    private let pubkey = "0f3c8b1a2d4e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f8"

    private func uri(name: String? = nil, url: String? = nil, imageURL: String? = nil) -> NostrConnectParser.ParsedURI {
        NostrConnectParser.ParsedURI(
            clientPubkey: pubkey,
            relays: ["wss://relay.example.com"],
            secret: "topsecret",
            requestedPerms: [],
            name: name,
            url: url,
            imageURL: imageURL,
            suggestedTrustLevel: .medium,
            isMultiAccount: false
        )
    }

    // MARK: - registrableDomain(fromURL:)

    func testPlainHost() {
        XCTAssertEqual(CallerIdentity.registrableDomain(fromURL: "https://clave.casa"), "clave.casa")
        XCTAssertEqual(CallerIdentity.registrableDomain(fromURL: "https://clave.casa/connect?x=1"), "clave.casa")
    }

    func testStripsLeadingWWW() {
        XCTAssertEqual(CallerIdentity.registrableDomain(fromURL: "https://www.clave.casa"), "clave.casa")
        XCTAssertEqual(CallerIdentity.registrableDomain(fromURL: "https://www.conduit.market/shop"), "conduit.market")
    }

    func testCollapsesSubdomainsToRegistrablePart() {
        XCTAssertEqual(CallerIdentity.registrableDomain(fromURL: "https://shop.conduit.market"), "conduit.market")
        XCTAssertEqual(CallerIdentity.registrableDomain(fromURL: "https://a.b.c.example.com"), "example.com")
    }

    func testKeepsWellKnownSecondLevelSuffixUnderTwoLetterTLD() {
        XCTAssertEqual(CallerIdentity.registrableDomain(fromURL: "https://app.example.co.uk"), "example.co.uk")
        XCTAssertEqual(CallerIdentity.registrableDomain(fromURL: "https://example.co.uk"), "example.co.uk")
        XCTAssertEqual(CallerIdentity.registrableDomain(fromURL: "https://www.shop.example.com.au"), "example.com.au")
        // A 2-letter TLD whose second label is NOT a well-known suffix stays two labels.
        XCTAssertEqual(CallerIdentity.registrableDomain(fromURL: "https://app.example.io"), "example.io")
        // A well-known-looking second label under a long TLD is just a name.
        XCTAssertEqual(CallerIdentity.registrableDomain(fromURL: "https://app.co.market"), "co.market")
    }

    func testLowercasesHost() {
        XCTAssertEqual(CallerIdentity.registrableDomain(fromURL: "HTTPS://Shop.Conduit.MARKET"), "conduit.market")
        XCTAssertEqual(CallerIdentity.registrableDomain(fromURL: "https://WWW.Clave.Casa"), "clave.casa")
    }

    func testIgnoresPortAndTrailingDot() {
        XCTAssertEqual(CallerIdentity.registrableDomain(fromURL: "https://clave.casa:8443/x"), "clave.casa")
        XCTAssertEqual(CallerIdentity.registrableDomain(fromURL: "https://clave.casa."), "clave.casa")
    }

    func testMissingURLIsNil() {
        XCTAssertNil(CallerIdentity.registrableDomain(fromURL: nil))
        XCTAssertNil(CallerIdentity.registrableDomain(fromURL: ""))
        XCTAssertNil(CallerIdentity.registrableDomain(fromURL: "   "))
    }

    func testInvalidURLIsNil() {
        XCTAssertNil(CallerIdentity.registrableDomain(fromURL: "not a url"))
        XCTAssertNil(CallerIdentity.registrableDomain(fromURL: "https://"))
        XCTAssertNil(CallerIdentity.registrableDomain(fromURL: "clave.casa"))          // no scheme
        XCTAssertNil(CallerIdentity.registrableDomain(fromURL: "https://intranet"))    // single label, no public suffix
    }

    func testNonHTTPSchemeIsNil() {
        XCTAssertNil(CallerIdentity.registrableDomain(fromURL: "ftp://clave.casa"))
        XCTAssertNil(CallerIdentity.registrableDomain(fromURL: "clave://connect"))
        XCTAssertNil(CallerIdentity.registrableDomain(fromURL: "javascript:alert(1)"))
        XCTAssertNil(CallerIdentity.registrableDomain(fromURL: "nostr:npub1abc"))
        // Plain http is still a web origin and is accepted.
        XCTAssertEqual(CallerIdentity.registrableDomain(fromURL: "http://clave.casa"), "clave.casa")
    }

    func testIPLiteralAndLocalhostAreNil() {
        XCTAssertNil(CallerIdentity.registrableDomain(fromURL: "https://192.168.1.10"))
        XCTAssertNil(CallerIdentity.registrableDomain(fromURL: "http://127.0.0.1:3000/cb"))
        XCTAssertNil(CallerIdentity.registrableDomain(fromURL: "http://[::1]/"))
        XCTAssertNil(CallerIdentity.registrableDomain(fromURL: "http://localhost"))
        XCTAssertNil(CallerIdentity.registrableDomain(fromURL: "http://LOCALHOST:5173"))
    }

    // MARK: - fingerprint(_:)

    func testFingerprintShape() {
        let fp = CallerIdentity.fingerprint(pubkey)
        XCTAssertEqual(fp, "0f3c8b1a…e7f8")
        XCTAssertEqual(fp.count, 13)
        XCTAssertTrue(fp.hasPrefix(String(pubkey.prefix(8))))
        XCTAssertTrue(fp.hasSuffix(String(pubkey.suffix(4))))
    }

    func testFingerprintLeavesShortKeysAlone() {
        XCTAssertEqual(CallerIdentity.fingerprint("abc123"), "abc123")
        XCTAssertEqual(CallerIdentity.fingerprint("123456789012"), "123456789012")
        XCTAssertEqual(CallerIdentity.fingerprint("1234567890123"), "12345678…0123")
    }

    // MARK: - displayDomain(for:)

    func testDisplayDomainPrefersDomainOverName() {
        XCTAssertEqual(
            CallerIdentity.displayDomain(for: uri(name: "Signin PoC", url: "https://clave.casa")),
            "clave.casa"
        )
    }

    func testDisplayDomainFallsBackToNameWhenNoUsableURL() {
        XCTAssertEqual(CallerIdentity.displayDomain(for: uri(name: "Signin PoC", url: nil)), "Signin PoC")
        XCTAssertEqual(CallerIdentity.displayDomain(for: uri(name: "Signin PoC", url: "not a url")), "Signin PoC")
        XCTAssertEqual(CallerIdentity.displayDomain(for: uri(name: "Signin PoC", url: "http://localhost")), "Signin PoC")
    }

    func testDisplayDomainFallsBackToFingerprintWhenNoURLAndNoName() {
        XCTAssertEqual(CallerIdentity.displayDomain(for: uri(name: nil, url: nil)), "0f3c8b1a…e7f8")
        // An empty name is treated as absent.
        XCTAssertEqual(CallerIdentity.displayDomain(for: uri(name: "", url: nil)), "0f3c8b1a…e7f8")
    }
}
