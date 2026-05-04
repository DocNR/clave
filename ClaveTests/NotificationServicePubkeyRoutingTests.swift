import XCTest
@testable import Clave

/// Task 6 of the multi-account sprint (`feat/multi-account`).
///
/// Verifies `SharedKeychain.resolveSignerPubkey(userInfo:)` —
/// the helper that decides which account to sign for on each NSE wake.
///
/// Strategy: APNs payload's `signer_pubkey` field (added by Stage A
/// proxy) is the primary source. Fallback: `currentSignerPubkeyHexKey`
/// UserDefaults — handles the transient case where the proxy hasn't
/// shipped Stage A yet but the iOS app is on Stage B.
///
/// The helper is `static` and side-effect-free (just two conditional
/// reads), so unit-testing it in isolation is straightforward. Full NSE
/// flow (Keychain load, decrypt, sign, publish) stays verified by
/// manual TestFlight testing.
///
/// Plan: ~/hq/clave/plans/2026-04-30-multi-account-sprint.md
/// Security audit: ~/hq/clave/security-audits/2026-04-30-multi-account-pre-implementation.md
final class NotificationServicePubkeyRoutingTests: XCTestCase {

    private let testPubkeyA = "aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666"
    private let testPubkeyB = "1111aaaa2222bbbb3333cccc4444dddd5555eeee6666ffff"

    override func setUp() {
        super.setUp()
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.currentSignerPubkeyHexKey)
    }

    override func tearDown() {
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.currentSignerPubkeyHexKey)
        super.tearDown()
    }

    func testResolveSignerPubkey_payloadFieldPresent_returnsPayloadValue() {
        // Even when currentSignerPubkeyHex is set, payload takes precedence.
        // This is critical for multi-account: a push for account B should
        // sign with B's nsec even if the user is currently on A.
        SharedConstants.sharedDefaults.set(testPubkeyA, forKey: SharedConstants.currentSignerPubkeyHexKey)

        let userInfo: [AnyHashable: Any] = [
            "signer_pubkey": testPubkeyB,
            "event_id": "abc",
            "relay_url": "wss://relay.example.com"
        ]

        let resolved = SharedKeychain.resolveSignerPubkey(userInfo: userInfo)
        XCTAssertEqual(resolved, testPubkeyB,
                       "Payload signer_pubkey must override currentSignerPubkeyHex")
    }

    func testResolveSignerPubkey_payloadFieldEmpty_fallsBackToCurrentSignerPubkeyHex() {
        // Defensive: if a malformed proxy ever sends an empty
        // signer_pubkey value, fall back to current. Not relying on the
        // proxy to never-emit-empty.
        SharedConstants.sharedDefaults.set(testPubkeyA, forKey: SharedConstants.currentSignerPubkeyHexKey)

        let userInfo: [AnyHashable: Any] = [
            "signer_pubkey": "",
            "event_id": "abc"
        ]

        let resolved = SharedKeychain.resolveSignerPubkey(userInfo: userInfo)
        XCTAssertEqual(resolved, testPubkeyA,
                       "Empty payload value must fall back to currentSignerPubkeyHex")
    }

    func testResolveSignerPubkey_payloadFieldMissing_fallsBackToCurrentSignerPubkeyHex() {
        // Stage A proxy hasn't shipped yet — payload doesn't include
        // signer_pubkey at all. Multi-account-Stage-B build should still
        // work for the migrated single-account user via the fallback.
        SharedConstants.sharedDefaults.set(testPubkeyA, forKey: SharedConstants.currentSignerPubkeyHexKey)

        let userInfo: [AnyHashable: Any] = [
            "event_id": "abc",
            "relay_url": "wss://relay.example.com"
        ]

        let resolved = SharedKeychain.resolveSignerPubkey(userInfo: userInfo)
        XCTAssertEqual(resolved, testPubkeyA,
                       "Missing payload field must fall back to currentSignerPubkeyHex")
    }

    func testResolveSignerPubkey_neitherSet_returnsEmptyString() {
        // Edge case: fresh-install user receives a push (shouldn't
        // happen in practice — proxy filters by registered tokens, and
        // a fresh install has no registration — but defensive). Empty
        // string return triggers NSE's silent-drop branch.
        // setUp() removed currentSignerPubkeyHexKey; payload has no field.

        let userInfo: [AnyHashable: Any] = [
            "event_id": "abc"
        ]

        let resolved = SharedKeychain.resolveSignerPubkey(userInfo: userInfo)
        XCTAssertEqual(resolved, "",
                       "No payload + no current signer must return empty string for silent-drop")
    }

    func testResolveSignerPubkey_payloadFieldWrongType_fallsBackToCurrentSignerPubkeyHex() {
        // Defensive: if the proxy ever sends signer_pubkey as a non-String
        // (e.g., accidentally serialized as a number), the cast fails and
        // we fall back to currentSignerPubkeyHex.
        SharedConstants.sharedDefaults.set(testPubkeyA, forKey: SharedConstants.currentSignerPubkeyHexKey)

        let userInfo: [AnyHashable: Any] = [
            "signer_pubkey": 12345,  // wrong type
            "event_id": "abc"
        ]

        let resolved = SharedKeychain.resolveSignerPubkey(userInfo: userInfo)
        XCTAssertEqual(resolved, testPubkeyA,
                       "Wrong-type payload value must fall back rather than throw")
    }
}
