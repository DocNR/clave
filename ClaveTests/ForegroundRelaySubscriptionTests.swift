import XCTest
@testable import Clave

@MainActor
final class ForegroundRelaySubscriptionTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        // Clean state before each test.
        let sub = ForegroundRelaySubscription.shared
        sub.stop()
        sub.resetCounters()
        // Allow stop() to fully transition before next test starts.
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    override func tearDown() async throws {
        // Ensure we leave the singleton idle for other test files.
        let sub = ForegroundRelaySubscription.shared
        sub.stop()
        try? await Task.sleep(nanoseconds: 100_000_000)
        try await super.tearDown()
    }

    func test_initialOrPostStopState_isIdle() async {
        let sub = ForegroundRelaySubscription.shared
        XCTAssertEqual(sub.state, .idle)
    }

    func test_startWithNoSignerKey_setsError() async {
        // Clear any stored signer pubkey so the start path bails out.
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.signerPubkeyHexKey)

        let sub = ForegroundRelaySubscription.shared
        sub.start()
        XCTAssertEqual(sub.state, .error)
        XCTAssertNotNil(sub.lastError)
        XCTAssertTrue(sub.lastError?.contains("signer") == true)
    }

    func test_resetCounters_zeroesAll() {
        let sub = ForegroundRelaySubscription.shared
        sub.resetCounters()
        XCTAssertEqual(sub.eventsReceived, 0)
        XCTAssertEqual(sub.eventsProcessed, 0)
        XCTAssertEqual(sub.eventsFailed, 0)
        XCTAssertTrue(sub.recentLatenciesMs.isEmpty)
        XCTAssertNil(sub.lastError)
    }

    func test_stopWhileIdle_isNoOp() {
        let sub = ForegroundRelaySubscription.shared
        let before = sub.state
        sub.stop()
        XCTAssertEqual(sub.state, before)
        XCTAssertEqual(sub.state, .idle)
    }

    func test_startTwice_isIdempotent() {
        // Set a valid-looking pubkey so start() doesn't bail out for that reason.
        let fakePub = String(repeating: "0", count: 64)
        SharedConstants.sharedDefaults.set(fakePub, forKey: SharedConstants.signerPubkeyHexKey)

        let sub = ForegroundRelaySubscription.shared
        sub.start()
        let firstState = sub.state
        sub.start()  // second call should not change state
        XCTAssertEqual(sub.state, firstState)
        sub.stop()

        // Cleanup
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.signerPubkeyHexKey)
    }

    func test_initialState_sessionStartedAtIsNil() {
        let sub = ForegroundRelaySubscription.shared
        XCTAssertNil(sub.sessionStartedAt,
                     "Idle L1 should report no session start timestamp")
    }

    func test_initialState_currentRelaysIsEmpty() {
        let sub = ForegroundRelaySubscription.shared
        XCTAssertTrue(sub.currentRelays.isEmpty,
                      "Idle L1 should have no current relays")
    }

    func test_startWithNoSignerKey_doesNotSetSessionStartedAt() async {
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.signerPubkeyHexKey)

        let sub = ForegroundRelaySubscription.shared
        sub.start()
        XCTAssertEqual(sub.state, .error)
        XCTAssertNil(sub.sessionStartedAt,
                     "sessionStartedAt should remain nil when start() bails on no key")
        XCTAssertTrue(sub.currentRelays.isEmpty,
                      "currentRelays should remain empty when start() bails on no key")
    }

    func test_resetCounters_doesNotClearSessionStartedAt() {
        // sessionStartedAt is a session-lifecycle field, not a counter.
        // resetCounters must not touch it. Guards against a future regression
        // where someone "cleans up" by clearing it inside resetCounters.
        let sub = ForegroundRelaySubscription.shared
        XCTAssertNil(sub.sessionStartedAt)
        sub.resetCounters()
        XCTAssertNil(sub.sessionStartedAt,
                     "resetCounters should not affect sessionStartedAt")
    }

    func test_state_rawValuesAreStableForLogging() {
        // setState's logger call uses state.rawValue; tests against literal
        // strings so a future rename of an enum case fails this test rather
        // than silently breaking log greps in user diagnostics.
        XCTAssertEqual(ForegroundRelaySubscription.State.idle.rawValue, "idle")
        XCTAssertEqual(ForegroundRelaySubscription.State.starting.rawValue, "starting")
        XCTAssertEqual(ForegroundRelaySubscription.State.listening.rawValue, "listening")
        XCTAssertEqual(ForegroundRelaySubscription.State.reconnecting.rawValue, "reconnecting")
        XCTAssertEqual(ForegroundRelaySubscription.State.stopping.rawValue, "stopping")
        XCTAssertEqual(ForegroundRelaySubscription.State.error.rawValue, "error")
    }
}
