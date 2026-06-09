import XCTest
@testable import Clave

/// NIP-46 logout — replay-guard coverage. `isLogoutReplay` is pure, tested
/// directly. The handleRequest gate (which reuses these) is exercised via the
/// async path + manual verification.
final class LightSignerLogoutTests: XCTestCase {

    func testIsLogoutReplay_rejectsFramePredatingPairing() {
        // pairing at t=10_000; a replayed logout from a prior session at t=9_000.
        XCTAssertTrue(LightSigner.isLogoutReplay(eventCreatedAt: 9_000, pairingConnectedAt: 10_000))
    }

    func testIsLogoutReplay_acceptsFreshLogout() {
        // logout sent after pairing (plus normal delay) is honored.
        XCTAssertFalse(LightSigner.isLogoutReplay(eventCreatedAt: 10_500, pairingConnectedAt: 10_000))
    }

    func testIsLogoutReplay_toleratesClockSkew() {
        // logout 100s "before" connectedAt (clock skew) within the 300s tolerance is honored.
        XCTAssertFalse(LightSigner.isLogoutReplay(eventCreatedAt: 9_900, pairingConnectedAt: 10_000))
    }
}
