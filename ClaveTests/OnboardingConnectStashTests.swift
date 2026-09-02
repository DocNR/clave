import XCTest
@testable import Clave

/// Unit tests for the zero-account "Sign in with Clave" connect-URI stash.
/// Each test uses an isolated UserDefaults suite so persistence is exercised
/// for real (not mocked) while staying hermetic.
final class OnboardingConnectStashTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var stash: OnboardingConnectStash!

    private let t0 = 1_000_000.0
    private let pkA = "aaa123def456abc123def456abc123def456abc123def456abc123def456abcd"
    private let pkB = "bbb123def456abc123def456abc123def456abc123def456abc123def456abcd"

    override func setUp() {
        super.setUp()
        suiteName = "OnboardingConnectStashTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        stash = OnboardingConnectStash(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        stash = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func parsed(_ pubkey: String, createdDuringFlow: Bool = false) throws -> NostrConnectParser.ParsedURI {
        var p = try NostrConnectParser.parse("nostrconnect://\(pubkey)?relay=wss%3A%2F%2Frelay.example.com&secret=topsecret")
        p.createdDuringFlow = createdDuringFlow
        return p
    }

    func testStoreThenPeek_roundTripsThroughPersistence() throws {
        stash.store(try parsed(pkA), now: t0)
        XCTAssertEqual(stash.peek(now: t0)?.clientPubkey, pkA)
    }

    func testPeek_withinTTL_returnsURI() throws {
        stash.store(try parsed(pkA), now: t0)
        XCTAssertEqual(stash.peek(now: t0 + 599)?.clientPubkey, pkA)
    }

    func testPeek_exactlyAtTTL_isStillValid() throws {
        // The stash uses `now - storedAt > ttl` (strictly greater), so exactly
        // 10 minutes old is the last still-valid instant.
        stash.store(try parsed(pkA), now: t0)
        XCTAssertEqual(stash.peek(now: t0 + OnboardingConnectStash.ttl)?.clientPubkey, pkA)
    }

    func testPeek_pastTTL_returnsNil() throws {
        stash.store(try parsed(pkA), now: t0)
        XCTAssertNil(stash.peek(now: t0 + 601))
    }

    func testExpiredPeek_scrubsSlot() throws {
        stash.store(try parsed(pkA), now: t0)
        _ = stash.peek(now: t0 + 601)             // expiry triggers scrub
        XCTAssertNil(stash.peek(now: t0))         // even "in time", the slot is gone
    }

    func testStore_lastWriterWins() throws {
        stash.store(try parsed(pkA), now: t0)
        stash.store(try parsed(pkB), now: t0 + 5)
        XCTAssertEqual(stash.peek(now: t0 + 6)?.clientPubkey, pkB)
    }

    func testPromote_returnsURIThenScrubs() throws {
        stash.store(try parsed(pkA), now: t0)
        XCTAssertEqual(stash.promote(now: t0 + 10)?.clientPubkey, pkA)
        XCTAssertNil(stash.promote(now: t0 + 11), "promote must consume the slot")
        XCTAssertNil(stash.peek(now: t0 + 11))
    }

    func testPromote_pastTTL_returnsNilAndScrubs() throws {
        stash.store(try parsed(pkA), now: t0)
        XCTAssertNil(stash.promote(now: t0 + 601), "expired stash must not replay")
        XCTAssertNil(stash.peek(now: t0))
    }

    func testCreatedDuringFlow_isNeverPersisted() throws {
        stash.store(try parsed(pkA, createdDuringFlow: true), now: t0)
        XCTAssertEqual(stash.peek(now: t0)?.createdDuringFlow, false,
                       "createdDuringFlow must die with the replay, never round-trip through storage")
    }

    func testClear_scrubsSlot() throws {
        stash.store(try parsed(pkA), now: t0)
        stash.clear()
        XCTAssertNil(stash.peek(now: t0))
    }
}
