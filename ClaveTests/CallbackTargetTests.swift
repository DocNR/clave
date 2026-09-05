import XCTest
@testable import Clave

/// The `callback=` return-leg rules (Sign in with Clave spec, `callback=` row).
///
/// Two halves, both pure:
///   - **host equality** — an https callback must have *exactly* the same host
///     as the caller's metadata `url`, compared through
///     `CallerIdentity.domain(fromURL:)` so there is no registrable-domain
///     collapse. A mismatch drops the callback: not shown, not opened.
///   - **the open decision** — auto-open only for a custom-scheme callback
///     after a foreground approval. An https callback opens a *new* Safari tab
///     rather than the tab holding the pending pairing, so web callers get a
///     "Return to *host*" hint instead.
final class CallbackTargetTests: XCTestCase {

    // MARK: - resolved: https host equality

    func testHttpsCallbackOnExactHostMatchIsKept() {
        XCTAssertEqual(
            CallbackTarget.resolved(
                callback: "https://conduit.market/return?state=abc",
                callerURL: "https://conduit.market"
            ),
            "https://conduit.market/return?state=abc"
        )
    }

    /// The whole point of the exact-host rule: a caller displayed as
    /// `attacker.github.io` can never call back as `github.io`, and two
    /// tenants of one shared suffix can never redirect to each other.
    func testHttpsCallbackOnSharedSuffixSiblingIsDropped() {
        XCTAssertNil(CallbackTarget.resolved(
            callback: "https://victim.pages.dev/return",
            callerURL: "https://attacker.pages.dev"
        ))
        XCTAssertNil(CallbackTarget.resolved(
            callback: "https://github.io/return",
            callerURL: "https://attacker.github.io"
        ))
    }

    func testHttpsCallbackOnSubdomainOfCallerIsDropped() {
        XCTAssertNil(CallbackTarget.resolved(
            callback: "https://evil.conduit.market/return",
            callerURL: "https://conduit.market"
        ))
        XCTAssertNil(CallbackTarget.resolved(
            callback: "https://conduit.market/return",
            callerURL: "https://app.conduit.market"
        ))
    }

    /// `domain(fromURL:)` strips exactly one leading `www.`, so apex and www
    /// are the same host on both sides of the comparison.
    func testWWWIsNormalisedOnBothSides() {
        XCTAssertEqual(
            CallbackTarget.resolved(
                callback: "https://www.conduit.market/return",
                callerURL: "https://conduit.market"
            ),
            "https://www.conduit.market/return"
        )
        XCTAssertEqual(
            CallbackTarget.resolved(
                callback: "https://conduit.market/return",
                callerURL: "https://www.conduit.market"
            ),
            "https://conduit.market/return"
        )
    }

    func testPunycodeHostsCompareLiterally() {
        // Same punycode host on both sides matches.
        XCTAssertEqual(
            CallbackTarget.resolved(
                callback: "https://xn--80ak8a1oqq.casa/return",
                callerURL: "https://xn--80ak8a1oqq.casa"
            ),
            "https://xn--80ak8a1oqq.casa/return"
        )
        // A punycode look-alike is a different host from the real one.
        XCTAssertNil(CallbackTarget.resolved(
            callback: "https://clave.casa/return",
            callerURL: "https://xn--80ak8a1oqq.casa"
        ))
    }

    /// `domain(fromURL:)` yields nil for IP literals, `localhost` and
    /// single-label hosts, so there is nothing to match and the callback goes.
    func testIPLiteralAndLocalhostCallbacksAreDropped() {
        XCTAssertNil(CallbackTarget.resolved(
            callback: "https://93.184.216.34/return",
            callerURL: "https://93.184.216.34"
        ))
        XCTAssertNil(CallbackTarget.resolved(
            callback: "https://localhost/return",
            callerURL: "https://localhost"
        ))
    }

    /// No caller `url` means no host to match against — an https callback has
    /// nothing binding it to the caller, so it is dropped.
    func testHttpsCallbackWithoutCallerURLIsDropped() {
        XCTAssertNil(CallbackTarget.resolved(
            callback: "https://conduit.market/return",
            callerURL: nil
        ))
    }

    /// The rule is on the host alone, so a scheme spelled in caps still
    /// resolves to the same host and still matches.
    func testSchemeCaseDoesNotAffectHostMatching() {
        XCTAssertEqual(
            CallbackTarget.resolved(
                callback: "HTTPS://conduit.market/return",
                callerURL: "https://conduit.market"
            ),
            "HTTPS://conduit.market/return"
        )
    }

    /// Host equality is the whole rule — the caller's metadata url and its
    /// callback may differ in scheme without breaking the binding.
    func testHttpCallbackMatchesHttpsCallerOnTheSameHost() {
        XCTAssertEqual(
            CallbackTarget.resolved(
                callback: "http://conduit.market/return",
                callerURL: "https://conduit.market"
            ),
            "http://conduit.market/return"
        )
    }

    // MARK: - resolved: custom schemes

    /// Custom-scheme callbacks are opened as given — there is no host to
    /// compare, and the scheme itself is the app's claim.
    func testCustomSchemeCallbackIsKeptWithoutCallerURL() {
        XCTAssertEqual(
            CallbackTarget.resolved(callback: "conduit://clave-return?state=abc", callerURL: nil),
            "conduit://clave-return?state=abc"
        )
    }

    func testCustomSchemeCallbackIsKeptEvenWhenCallerHostDiffers() {
        XCTAssertEqual(
            CallbackTarget.resolved(callback: "conduit://return", callerURL: "https://example.com"),
            "conduit://return"
        )
    }

    func testNilCallbackResolvesToNil() {
        XCTAssertNil(CallbackTarget.resolved(callback: nil, callerURL: "https://conduit.market"))
    }

    // MARK: - displayTarget

    /// Shown with the same domain-first rendering as the caller headline.
    func testDisplayTargetIsTheHostForHttps() {
        XCTAssertEqual(
            CallbackTarget.displayTarget(
                callback: "https://www.conduit.market/return?state=abc",
                callerURL: "https://conduit.market"
            ),
            "conduit.market"
        )
    }

    /// A custom scheme has no host; the scheme itself is what the user sees.
    func testDisplayTargetIsTheSchemeForCustomScheme() {
        XCTAssertEqual(
            CallbackTarget.displayTarget(callback: "conduit://clave-return?state=abc", callerURL: nil),
            "conduit://"
        )
    }

    func testDisplayTargetIsNilWhenCallbackIsDropped() {
        XCTAssertNil(CallbackTarget.displayTarget(
            callback: "https://victim.pages.dev/return",
            callerURL: "https://attacker.pages.dev"
        ))
    }

    // MARK: - the ApprovalSheet disclosure line

    /// An https callback is only ever a hint — Clave does not open it — so the
    /// line must not promise a return it will not perform. It names where to
    /// go back to, domain-first, exactly as the caller headline is rendered.
    func testSheetDisclosureForHttpsPointsBackWithoutPromisingAReturn() {
        XCTAssertEqual(
            CallbackTarget.sheetDisclosure(
                callback: "https://www.conduit.market/return?state=abc",
                callerURL: "https://conduit.market"
            ),
            "Afterwards, return to conduit.market"
        )
    }

    /// A custom scheme *is* opened, so here the promise is accurate.
    func testSheetDisclosureForCustomSchemePromisesTheReturn() {
        XCTAssertEqual(
            CallbackTarget.sheetDisclosure(callback: "conduit://return", callerURL: nil),
            "Sends you back to conduit://"
        )
    }

    /// A dropped callback is not shown at all — no line, and no hint that the
    /// caller asked for something Clave refused.
    func testSheetDisclosureIsNilWhenCallbackIsDropped() {
        XCTAssertNil(CallbackTarget.sheetDisclosure(
            callback: "https://victim.pages.dev/return",
            callerURL: "https://attacker.pages.dev"
        ))
    }

    func testSheetDisclosureIsNilWithoutACallback() {
        XCTAssertNil(CallbackTarget.sheetDisclosure(callback: nil, callerURL: "https://conduit.market"))
    }

    // MARK: - the open decision

    func testCustomSchemeOpensAfterForegroundApproval() {
        XCTAssertEqual(
            CallbackTarget.outcome(
                callback: "conduit://return?state=abc",
                callerURL: "https://conduit.market",
                approved: true,
                origin: .approvalSheet
            ),
            .open(url: "conduit://return?state=abc")
        )
    }

    /// An https callback would land in a *new* Safari tab, not the tab holding
    /// the pending pairing — so it is a hint, never an auto-open.
    func testHttpsCallbackHintsRatherThanOpens() {
        XCTAssertEqual(
            CallbackTarget.outcome(
                callback: "https://conduit.market/return?state=abc",
                callerURL: "https://conduit.market",
                approved: true,
                origin: .approvalSheet
            ),
            .hint(host: "conduit.market")
        )
    }

    func testDenialNeverReturns() {
        XCTAssertEqual(
            CallbackTarget.outcome(
                callback: "conduit://return",
                callerURL: "https://conduit.market",
                approved: false,
                origin: .approvalSheet
            ),
            .noReturn
        )
    }

    /// The lock-screen / NSE signing path must never open anything: there is
    /// no foreground approval behind it.
    func testLockScreenOriginNeverReturns() {
        XCTAssertEqual(
            CallbackTarget.outcome(
                callback: "conduit://return",
                callerURL: "https://conduit.market",
                approved: true,
                origin: .lockScreen
            ),
            .noReturn
        )
    }

    func testDroppedCallbackNeverReturns() {
        XCTAssertEqual(
            CallbackTarget.outcome(
                callback: "https://victim.pages.dev/return",
                callerURL: "https://attacker.pages.dev",
                approved: true,
                origin: .approvalSheet
            ),
            .noReturn
        )
    }

    func testNoCallbackNeverReturns() {
        XCTAssertEqual(
            CallbackTarget.outcome(
                callback: nil,
                callerURL: "https://conduit.market",
                approved: true,
                origin: .approvalSheet
            ),
            .noReturn
        )
    }
}
