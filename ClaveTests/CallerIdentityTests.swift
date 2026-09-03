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

    // MARK: - domain(fromURL:)

    func testPlainHost() {
        XCTAssertEqual(CallerIdentity.domain(fromURL: "https://clave.casa"), "clave.casa")
        XCTAssertEqual(CallerIdentity.domain(fromURL: "https://clave.casa/connect?x=1"), "clave.casa")
    }

    func testStripsOneLeadingWWW() {
        XCTAssertEqual(CallerIdentity.domain(fromURL: "https://www.clave.casa"), "clave.casa")
        XCTAssertEqual(CallerIdentity.domain(fromURL: "https://www.conduit.market/shop"), "conduit.market")
        // Exactly one "www." is stripped; anything left is part of the host.
        XCTAssertEqual(CallerIdentity.domain(fromURL: "https://www.www.clave.casa"), "www.clave.casa")
    }

    func testKeepsFullHostWithoutCollapsingSubdomains() {
        // No public-suffix collapse. A last-two-labels rule would launder
        // attacker.github.io into "github.io" (and pages.dev, vercel.app,
        // netlify.app, trycloudflare.com, …) — the full host is what the
        // user must see.
        XCTAssertEqual(CallerIdentity.domain(fromURL: "https://shop.conduit.market"), "shop.conduit.market")
        XCTAssertEqual(CallerIdentity.domain(fromURL: "https://a.b.c.example.com"), "a.b.c.example.com")
        XCTAssertEqual(CallerIdentity.domain(fromURL: "https://attacker.github.io"), "attacker.github.io")
        XCTAssertEqual(CallerIdentity.domain(fromURL: "https://attacker.pages.dev"), "attacker.pages.dev")
    }

    func testKeepsFullHostUnderCountryCodeSuffixes() {
        XCTAssertEqual(CallerIdentity.domain(fromURL: "https://app.example.co.uk"), "app.example.co.uk")
        XCTAssertEqual(CallerIdentity.domain(fromURL: "https://example.co.uk"), "example.co.uk")
        XCTAssertEqual(CallerIdentity.domain(fromURL: "https://www.shop.example.com.au"), "shop.example.com.au")
        XCTAssertEqual(CallerIdentity.domain(fromURL: "https://app.example.io"), "app.example.io")
        XCTAssertEqual(CallerIdentity.domain(fromURL: "https://attacker.nhs.uk"), "attacker.nhs.uk")
    }

    func testLowercasesHost() {
        XCTAssertEqual(CallerIdentity.domain(fromURL: "HTTPS://Shop.Conduit.MARKET"), "shop.conduit.market")
        XCTAssertEqual(CallerIdentity.domain(fromURL: "https://WWW.Clave.Casa"), "clave.casa")
    }

    // MARK: - IDN homograph hardening (ASCII-only host)

    func testPunycodeHostIsShownLiterally() {
        // Foundation IDNA-decodes an xn-- host to Unicode, which would render
        // a Cyrillic "сӏаѵе.casa" pixel-identical to clave.casa. The literal
        // punycode is visibly not the real domain.
        XCTAssertEqual(CallerIdentity.domain(fromURL: "https://xn--80ak8a1oqq.casa"), "xn--80ak8a1oqq.casa")
    }

    func testRawUnicodeHostIsNil() {
        XCTAssertNil(CallerIdentity.domain(fromURL: "https://сӏаѵе.casa"))          // Cyrillic homograph
        XCTAssertNil(CallerIdentity.domain(fromURL: "https://cl\u{00AD}ave.casa"))   // soft hyphen
        XCTAssertNil(CallerIdentity.domain(fromURL: "https://ＣＬＡＶＥ.casa"))          // fullwidth
    }

    func testPercentEscapedHostIsNil() {
        XCTAssertNil(CallerIdentity.domain(fromURL: "https://clave.casa%E2%80%8Bevil.com"))  // ZWSP
        XCTAssertNil(CallerIdentity.domain(fromURL: "https://clave%E2%80%AE.casa"))          // RLO
        XCTAssertNil(CallerIdentity.domain(fromURL: "https://clave.casa%2Eevil.com"))
    }

    func testIgnoresPortAndTrailingDot() {
        XCTAssertEqual(CallerIdentity.domain(fromURL: "https://clave.casa:8443/x"), "clave.casa")
        XCTAssertEqual(CallerIdentity.domain(fromURL: "https://clave.casa."), "clave.casa")
    }

    func testMissingURLIsNil() {
        XCTAssertNil(CallerIdentity.domain(fromURL: nil))
        XCTAssertNil(CallerIdentity.domain(fromURL: ""))
        XCTAssertNil(CallerIdentity.domain(fromURL: "   "))
    }

    func testInvalidURLIsNil() {
        XCTAssertNil(CallerIdentity.domain(fromURL: "not a url"))
        XCTAssertNil(CallerIdentity.domain(fromURL: "https://"))
        XCTAssertNil(CallerIdentity.domain(fromURL: "clave.casa"))          // no scheme
        XCTAssertNil(CallerIdentity.domain(fromURL: "https://intranet"))    // single label, no public suffix
    }

    func testNonHTTPSchemeIsNil() {
        XCTAssertNil(CallerIdentity.domain(fromURL: "ftp://clave.casa"))
        XCTAssertNil(CallerIdentity.domain(fromURL: "clave://connect"))
        XCTAssertNil(CallerIdentity.domain(fromURL: "javascript:alert(1)"))
        XCTAssertNil(CallerIdentity.domain(fromURL: "nostr:npub1abc"))
        // Plain http is still a web origin and is accepted.
        XCTAssertEqual(CallerIdentity.domain(fromURL: "http://clave.casa"), "clave.casa")
    }

    func testIPLiteralAndLocalhostAreNil() {
        XCTAssertNil(CallerIdentity.domain(fromURL: "https://192.168.1.10"))
        XCTAssertNil(CallerIdentity.domain(fromURL: "http://127.0.0.1:3000/cb"))
        XCTAssertNil(CallerIdentity.domain(fromURL: "http://[::1]/"))
        XCTAssertNil(CallerIdentity.domain(fromURL: "http://localhost"))
        XCTAssertNil(CallerIdentity.domain(fromURL: "http://LOCALHOST:5173"))
    }

    func testIPv4ShorthandSpellingsAreNil() {
        // No TLD is numeric, so any numeric last label is an IP literal in
        // some spelling — never a domain.
        XCTAssertNil(CallerIdentity.domain(fromURL: "https://127.1"))
        XCTAssertNil(CallerIdentity.domain(fromURL: "https://0x7f.0.0.1"))
        XCTAssertNil(CallerIdentity.domain(fromURL: "https://1.2.3.4.5"))
        XCTAssertNil(CallerIdentity.domain(fromURL: "https://10.0.0.1:8080/"))
    }

    func testAuthorityMustFollowTheSchemeDirectly() {
        // URLComponents accepts these with scheme "https" but no host; matching
        // the first "://" anywhere in the string would display "clave.casa".
        XCTAssertNil(CallerIdentity.domain(fromURL: "https:evil://clave.casa"))
        XCTAssertNil(CallerIdentity.domain(fromURL: "https:/evil.com/x://clave.casa"))
        XCTAssertNil(CallerIdentity.domain(fromURL: "HTTPS:x://clave.casa"))
        XCTAssertNil(CallerIdentity.domain(fromURL: "https:?x://clave.casa"))
        XCTAssertNil(CallerIdentity.domain(fromURL: "https:#x://clave.casa"))
        // Case-insensitive scheme is still fine when the authority follows it.
        XCTAssertEqual(CallerIdentity.domain(fromURL: "HTTPS://clave.casa"), "clave.casa")
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

    // MARK: - headline(url:pubkey:)

    func testHeadlinePrefersDomain() {
        XCTAssertEqual(CallerIdentity.headline(url: "https://clave.casa", pubkey: pubkey), "clave.casa")
        XCTAssertEqual(CallerIdentity.headline(url: "https://shop.conduit.market", pubkey: pubkey), "shop.conduit.market")
    }

    func testHeadlineFallsBackToFingerprintWhenNoUsableURL() {
        XCTAssertEqual(CallerIdentity.headline(url: nil, pubkey: pubkey), "0f3c8b1a…e7f8")
        XCTAssertEqual(CallerIdentity.headline(url: "not a url", pubkey: pubkey), "0f3c8b1a…e7f8")
        XCTAssertEqual(CallerIdentity.headline(url: "http://localhost", pubkey: pubkey), "0f3c8b1a…e7f8")
    }

    func testHeadlineNeverUsesSelfAssertedName() {
        // The name is not even an input: a caller with no url and
        // name="clave.casa" gets the fingerprint, not "clave.casa".
        let caller = uri(name: "clave.casa", url: nil)
        XCTAssertEqual(CallerIdentity.headline(url: caller.url, pubkey: caller.clientPubkey), "0f3c8b1a…e7f8")
    }

    // MARK: - name(_:) / unverifiedClaim(name:imageURL:)

    func testNameTrimsAndTreatsBlankAsAbsent() {
        XCTAssertEqual(CallerIdentity.name("  Signin PoC \n"), "Signin PoC")
        XCTAssertNil(CallerIdentity.name(nil))
        XCTAssertNil(CallerIdentity.name(""))
        XCTAssertNil(CallerIdentity.name("   "))
        XCTAssertNil(CallerIdentity.name("\n\t"))
    }

    func testUnverifiedClaimForName() {
        XCTAssertEqual(CallerIdentity.unverifiedClaim(name: "Signin PoC", imageURL: nil),
                       "calls itself “Signin PoC”")
        // A name wins over an image, and is trimmed.
        XCTAssertEqual(CallerIdentity.unverifiedClaim(name: " Signin PoC ", imageURL: "https://clave.casa/i.png"),
                       "calls itself “Signin PoC”")
    }

    func testUnverifiedClaimForIconOnlyCaller() {
        XCTAssertEqual(CallerIdentity.unverifiedClaim(name: nil, imageURL: "https://clave.casa/i.png"), "icon")
        XCTAssertEqual(CallerIdentity.unverifiedClaim(name: "   ", imageURL: "https://clave.casa/i.png"), "icon")
    }

    func testUnverifiedClaimIsNilWhenNothingSelfAsserted() {
        XCTAssertNil(CallerIdentity.unverifiedClaim(name: nil, imageURL: nil))
        XCTAssertNil(CallerIdentity.unverifiedClaim(name: "", imageURL: ""))
        XCTAssertNil(CallerIdentity.unverifiedClaim(name: "  ", imageURL: "  "))
    }

    func testUnverifiedMarkerIsFixedText() {
        XCTAssertEqual(CallerIdentity.unverifiedMarker, "· unverified")
    }
}
