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
}
