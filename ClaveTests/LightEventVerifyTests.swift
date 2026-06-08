import XCTest
import CryptoKit
@testable import Clave

final class LightEventVerifyTests: XCTestCase {

    private let testPrivateKey = Data(hexString: "0000000000000000000000000000000000000000000000000000000000000001")!

    // MARK: - Independent cross-implementation vector

    /// Signed by `nak` (go-nostr, an independent spec-correct implementation),
    /// sec=0x01, created_at=1700000000. Multi-element tag + `/` in content.
    /// This proves NIP-01 conformance, not just round-trip self-consistency.
    func testVerify_acceptsIndependentlySignedEvent() {
        let event: [String: Any] = [
            "kind": 24133,
            "id": "45879c27b4f71dc9613acdaf6b9a63c5d41fdf07502dad5983f1cf20b5fa36b8",
            "pubkey": "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
            "created_at": 1700000000,
            "tags": [["t", "a", "b", "c"]],
            "content": "ab/cd",
            "sig": "85a4a853cfae404cac2d2a3852dc96b515fbce22864fcc7d57a4bc329cd46eb21a0657ecbbeaf7c79cb88045061c71b826aceaea53404cc004f710e322d367e1"
        ]
        XCTAssertTrue(LightEvent.verify(event: event),
                      "must verify an independently-signed (nak/go-nostr) event — proves NIP-01 conformance, not just round-trip consistency")
    }

    // MARK: - Round-trip

    func testVerify_roundTripSignedEvent() throws {
        let signed = try LightEvent.sign(
            privateKey: testPrivateKey,
            kind: 1,
            content: "hello world",
            tags: [["e", "abc"], ["p", "def"]]
        )
        XCTAssertTrue(LightEvent.verify(event: signed.toDict()),
                      "a freshly signed event must verify")
    }

    func testVerify_roundTripRandomKey() throws {
        var randBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &randBytes)
        let randomKey = Data(randBytes)

        let signed = try LightEvent.sign(
            privateKey: randomKey,
            kind: 30078,
            content: "arbitrary application data",
            tags: [["d", "spectr_decks"]]
        )
        XCTAssertTrue(LightEvent.verify(event: signed.toDict()),
                      "a freshly signed event with a random key must verify")
    }

    // MARK: - Tamper detection (fail-closed)

    func testVerify_rejectsTamperedCreatedAt() throws {
        let signed = try LightEvent.sign(
            privateKey: testPrivateKey,
            kind: 1,
            content: "tamper test",
            tags: []
        )
        var dict = signed.toDict()
        dict["created_at"] = signed.createdAt + 1
        XCTAssertFalse(LightEvent.verify(event: dict),
                       "tampering created_at must invalidate the id/signature")
    }

    func testVerify_rejectsTamperedContent() throws {
        let signed = try LightEvent.sign(
            privateKey: testPrivateKey,
            kind: 1,
            content: "original content",
            tags: []
        )
        var dict = signed.toDict()
        dict["content"] = "evil content"
        XCTAssertFalse(LightEvent.verify(event: dict),
                       "tampering content must invalidate the id/signature")
    }

    func testVerify_rejectsTamperedId() throws {
        let signed = try LightEvent.sign(
            privateKey: testPrivateKey,
            kind: 1,
            content: "id tamper test",
            tags: []
        )
        var dict = signed.toDict()
        // Flip the leading hex nibble so it stays well-formed but wrong.
        let id = signed.id
        let flipped = (id.first == "0" ? "1" : "0") + id.dropFirst()
        dict["id"] = flipped
        XCTAssertFalse(LightEvent.verify(event: dict),
                       "a recomputed id mismatch must fail")
    }

    func testVerify_rejectsTamperedSig() throws {
        let signed = try LightEvent.sign(
            privateKey: testPrivateKey,
            kind: 1,
            content: "sig tamper test",
            tags: []
        )
        var dict = signed.toDict()
        let sig = signed.sig
        let flipped = (sig.first == "0" ? "1" : "0") + sig.dropFirst()
        dict["sig"] = flipped
        XCTAssertFalse(LightEvent.verify(event: dict),
                       "a tampered signature must fail BIP-340 verification")
    }

    // MARK: - Control-char escaping round-trip

    /// Proves the control-char escaping sweep (C3.1) is internally consistent:
    /// sign content containing backspace/vertical-tab/form-feed/null, then verify.
    func testVerify_roundTripControlCharContent() throws {
        let signed = try LightEvent.sign(
            privateKey: testPrivateKey,
            kind: 1,
            content: "\u{08}\u{0B}\u{0C}\u{00}",
            tags: []
        )
        XCTAssertTrue(LightEvent.verify(event: signed.toDict()),
                      "control-char content must round-trip through escaping consistently")
    }

    // MARK: - Malformed input (fail-closed)

    func testVerify_rejectsMissingFields() {
        let event: [String: Any] = [
            "kind": 1,
            "id": "00",
            "pubkey": "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
            // missing created_at, tags, content, sig
        ]
        XCTAssertFalse(LightEvent.verify(event: event),
                       "missing required fields must fail closed")
    }
}
