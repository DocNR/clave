import XCTest
@testable import Clave

/// Direct unit tests for `LightSigner.processRequest`. This file is structured
/// so future RPC methods (connect, get_public_key, describe, etc.) can be
/// added here without machinery for encrypted-envelope construction.
final class LightSignerProcessRequestTests: XCTestCase {

    private func randomKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        return Data(bytes)
    }

    /// `switch_relays` must return the JSON literal `null` so that NDK-based
    /// clients doing `JSON.parse(response.result)` resolve to null (the NIP-46
    /// "nothing to be changed" sentinel). Returning a concrete relay array
    /// triggers welshman pool migration in Coracle and stalls the pairing UI.
    func testSwitchRelaysReturnsJSONNull() {
        let privateKey = randomKey()
        let (result, error) = LightSigner.processRequest(
            method: "switch_relays",
            params: [],
            privateKey: privateKey
        )
        XCTAssertEqual(result, "null", "switch_relays must return the string \"null\" so clients JSON.parse it to null")
        XCTAssertNil(error)
    }

    /// Guard against a regression where switch_relays returns any relay URL,
    /// including `SharedConstants.relayURL`.
    func testSwitchRelaysResultDoesNotContainRelayURL() {
        let privateKey = randomKey()
        let (result, _) = LightSigner.processRequest(
            method: "switch_relays",
            params: [],
            privateKey: privateKey
        )
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.contains("wss://"), "switch_relays result must not contain any wss:// URL")
        XCTAssertFalse(result!.contains(SharedConstants.relayURL), "switch_relays result must not contain SharedConstants.relayURL")
    }
}
