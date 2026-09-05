import XCTest
@testable import Clave

/// Parse-time handling of the Phase-2 `callback=` param (Sign in with Clave
/// spec, `callback=` row): the parser keeps a callback that is *shaped* like
/// something safe to hand `UIApplication.open`, and drops everything else.
///
/// Deliberately split from the host-equality rule: matching an https callback
/// against the caller's metadata `url` needs `CallerIdentity`, which is in the
/// app target only (the NSE compiles `NostrConnectParser` too, and must never
/// open a callback at all). See `CallbackTargetTests` for that half.
final class NostrConnectParserCallbackTests: XCTestCase {

    private let pubkey = "83f3b2ae6aa368e8275397b9c26cf550101d63ebaab900d19dd4a4429f5ad8f5"

    /// Builds a minimally-valid nostrconnect URI with `callback` set to the
    /// given raw (un-encoded) value.
    private func uri(callback: String?) -> String {
        var s = "nostrconnect://\(pubkey)?relay=wss%3A%2F%2Frelay.example.com&secret=s"
        if let callback {
            let encoded = callback.addingPercentEncoding(
                withAllowedCharacters: CharacterSet(charactersIn: "")
            ) ?? callback
            s += "&callback=\(encoded)"
        }
        return s
    }

    private func parsedCallback(_ raw: String?) throws -> String? {
        try NostrConnectParser.parse(uri(callback: raw)).callback
    }

    // MARK: - Absent

    func testNoCallbackParamYieldsNil() throws {
        XCTAssertNil(try parsedCallback(nil))
    }

    func testEmptyCallbackYieldsNil() throws {
        XCTAssertNil(try parsedCallback(""))
        XCTAssertNil(try parsedCallback("   "))
    }

    // MARK: - Kept

    func testKeepsHttpsCallback() throws {
        XCTAssertEqual(
            try parsedCallback("https://conduit.market/return?state=abc123"),
            "https://conduit.market/return?state=abc123"
        )
    }

    func testKeepsCustomSchemeCallback() throws {
        XCTAssertEqual(
            try parsedCallback("conduit://clave-return?state=abc123"),
            "conduit://clave-return?state=abc123"
        )
    }

    /// An opaque custom scheme (no "//" authority) is still openable.
    func testKeepsOpaqueCustomScheme() throws {
        XCTAssertEqual(try parsedCallback("conduit:return"), "conduit:return")
    }

    func testTrimsSurroundingWhitespace() throws {
        XCTAssertEqual(try parsedCallback("  conduit://return  "), "conduit://return")
    }

    // MARK: - Dropped: dangerous schemes

    func testDropsJavascriptScheme() throws {
        XCTAssertNil(try parsedCallback("javascript:alert(1)"))
    }

    func testDropsJavascriptSchemeRegardlessOfCase() throws {
        XCTAssertNil(try parsedCallback("JaVaScRiPt:alert(1)"))
    }

    func testDropsDataScheme() throws {
        XCTAssertNil(try parsedCallback("data:text/html;base64,PHNjcmlwdD4="))
    }

    func testDropsFileScheme() throws {
        XCTAssertNil(try parsedCallback("file:///etc/passwd"))
    }

    // MARK: - Dropped: userinfo

    func testDropsCallbackWithUserinfo() throws {
        XCTAssertNil(try parsedCallback("https://user@evil.example/return"))
    }

    func testDropsCallbackWithUserAndPassword() throws {
        XCTAssertNil(try parsedCallback("https://user:pw@evil.example/return"))
    }

    /// The authority ends at the first "/", "?" or "#" — an "@" after that is
    /// path/query data, not userinfo, and must not cause a false drop.
    func testKeepsAtSignInPathOrQuery() throws {
        XCTAssertEqual(
            try parsedCallback("https://conduit.market/return?to=a@b.com"),
            "https://conduit.market/return?to=a@b.com"
        )
    }

    // MARK: - Dropped: malformed

    func testDropsSchemelessCallback() throws {
        XCTAssertNil(try parsedCallback("conduit.market/return"))
        XCTAssertNil(try parsedCallback("/return"))
    }

    func testDropsCallbackContainingWhitespaceOrControls() throws {
        XCTAssertNil(try parsedCallback("java\nscript:alert(1)"))
        XCTAssertNil(try parsedCallback("https://conduit.market/a b"))
    }

    /// A scheme must be RFC-3986 shaped (`[a-z][a-z0-9+.-]*`); anything else
    /// is not a scheme we are willing to hand to the system.
    func testDropsMalformedScheme() throws {
        XCTAssertNil(try parsedCallback("1conduit://return"))
        XCTAssertNil(try parsedCallback("con duit://return"))
    }

    // MARK: - Dropped: schemes the system itself acts on

    /// `UIApplication.open` hands these to iOS, not to a partner app: the
    /// dialler, Messages, Mail, FaceTime, the App Store and the enterprise
    /// installer, Shortcuts, Settings. None is a place a partner returns to,
    /// and several act on the user's behalf off the tail of an approval, so
    /// they are never a callback — whatever the case of the scheme.
    func testDropsSystemHandledSchemes() throws {
        let rejected = [
            "tel:+15555550100",
            "sms:+15555550100&body=hi",
            "mailto:someone@example.com",
            "facetime:someone@example.com",
            "facetime-audio:someone@example.com",
            "itms-services://?action=download-manifest&url=https://evil.example/app.plist",
            "itms-apps://apps.apple.com/app/id1",
            "ITMS-APPS://apps.apple.com/app/id1",
            "shortcuts://run-shortcut?name=x",
            "app-settings:",
            "prefs:root=General",
            "App-Prefs:root=General",
            "x-apple-health://",
            "about:blank",
            "blob:https://conduit.market/uuid",
            "vbscript:msgbox(1)",
        ]
        for callback in rejected {
            XCTAssertNil(try parsedCallback(callback), callback)
        }
    }

    /// Clave's own schemes can never be a callback: opening one would route a
    /// second connect request straight back into Clave off the tail of an
    /// approval — a chained prompt the user never asked for.
    func testDropsClavesOwnSchemes() throws {
        XCTAssertNil(try parsedCallback("nostrconnect://\(pubkey)?relay=wss%3A%2F%2Fr.example&secret=x"))
        XCTAssertNil(try parsedCallback("clave://connect?uri=nostrconnect%3A%2F%2Fx"))
        XCTAssertNil(try parsedCallback("bunker://\(pubkey)?relay=wss%3A%2F%2Fr.example"))
    }

    /// Reverse-DNS app schemes are common and legitimate; the denylist must
    /// not catch them.
    func testKeepsReverseDNSCustomScheme() throws {
        XCTAssertEqual(
            try parsedCallback("com.example.app://clave-return?state=abc"),
            "com.example.app://clave-return?state=abc"
        )
    }

    // MARK: - Dropped: decoding edges

    /// `URLComponents.queryItems` decodes the value exactly once before it is
    /// validated. A double-encoded URL therefore arrives with no literal ":"
    /// and is dropped as scheme-less rather than decoded again.
    func testDoubleEncodedCallbackIsDropped() throws {
        XCTAssertNil(try parsedCallback("https%3A%2F%2Fevil.example%2F"))
    }

    /// A fullwidth colon (U+FF1A) is not a scheme separator.
    func testFullwidthColonIsNotAScheme() throws {
        XCTAssertNil(try parsedCallback("https\u{FF1A}//evil.example"))
    }

    // MARK: - Persistence

    /// `callback` rides the onboarding stash across the App Store round trip,
    /// so it must be in `CodingKeys` — unlike `createdDuringFlow`, which must
    /// stay out of it.
    func testCallbackSurvivesCodableRoundTrip() throws {
        let parsed = try NostrConnectParser.parse(uri(callback: "conduit://return?state=xyz"))
        let data = try JSONEncoder().encode(parsed)
        let decoded = try JSONDecoder().decode(NostrConnectParser.ParsedURI.self, from: data)
        XCTAssertEqual(decoded.callback, "conduit://return?state=xyz")
    }

    func testCreatedDuringFlowStillNotPersisted() throws {
        var parsed = try NostrConnectParser.parse(uri(callback: "conduit://return"))
        parsed.createdDuringFlow = true
        let data = try JSONEncoder().encode(parsed)
        let decoded = try JSONDecoder().decode(NostrConnectParser.ParsedURI.self, from: data)
        XCTAssertFalse(decoded.createdDuringFlow)
    }
}
