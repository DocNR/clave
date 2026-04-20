import XCTest
@testable import Clave

/// Tests that LightSigner.handleRequest honors the responseRelayUrl parameter
/// (the probe E fix). Without this, the NSE fallback publishes signed responses
/// to SharedConstants.relayURL regardless of where the request came from, which
/// breaks end-to-end signing for any client whose URI doesn't include
/// relay.powr.build.
///
/// We can't easily intercept LightRelay inside handleRequest without a larger
/// refactor, so this file focuses on compile-time assertions (the signature
/// change itself is the fix; runtime behavior is covered by the device
/// verification matrix).
final class LightSignerResponseRelayUrlTests: XCTestCase {

    /// Compile-time check: handleRequest accepts responseRelayUrl.
    /// If this file fails to compile, the signature regressed.
    func testHandleRequestAcceptsResponseRelayUrl() async throws {
        let dummyKey = Data(repeating: 0, count: 32)
        let dummyEvent: [String: Any] = [
            "id": "deadbeef",
            "pubkey": "0".padding(toLength: 64, withPad: "0", startingAt: 0),
            "content": "not-a-valid-ciphertext",
            "kind": 24133,
            "tags": [],
        ]
        // We don't care about the result — we care that this compiles with
        // `responseRelayUrl:` in the argument list.
        _ = try? await LightSigner.handleRequest(
            privateKey: dummyKey,
            requestEvent: dummyEvent,
            responseRelayUrl: "wss://bucket.coracle.social"
        )
        XCTAssertTrue(true)
    }

    /// Compile-time check: responseRelayUrl is optional and defaults to nil.
    /// Call sites that don't care about V2 (existing code paths) must still
    /// compile unchanged.
    func testHandleRequestResponseRelayUrlIsOptional() async throws {
        let dummyKey = Data(repeating: 0, count: 32)
        let dummyEvent: [String: Any] = ["content": ""]
        _ = try? await LightSigner.handleRequest(
            privateKey: dummyKey,
            requestEvent: dummyEvent
            // no responseRelayUrl — must still compile
        )
        XCTAssertTrue(true)
    }
}
