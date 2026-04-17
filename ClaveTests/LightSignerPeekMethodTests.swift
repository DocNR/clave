import XCTest
@testable import Clave

final class LightSignerPeekMethodTests: XCTestCase {

    /// Build a kind:24133 event signed by `senderPriv`, encrypted to `recipientPub`, with the given NIP-46 request payload.
    private func makeRequestEvent(
        senderPriv: Data,
        recipientPub: Data,
        requestJSON: String
    ) throws -> [String: Any] {
        let encrypted = try LightCrypto.nip44Encrypt(
            privateKey: senderPriv,
            publicKey: recipientPub,
            plaintext: requestJSON
        )
        let signed = try LightEvent.sign(
            privateKey: senderPriv,
            kind: 24133,
            content: encrypted,
            tags: [["p", try LightEvent.pubkeyHex(from: senderPriv)]]
        )
        return [
            "id": signed.id,
            "pubkey": signed.pubkey,
            "created_at": signed.createdAt,
            "kind": signed.kind,
            "tags": signed.tags,
            "content": signed.content,
            "sig": signed.sig
        ]
    }

    private func randomKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        return Data(bytes)
    }

    func testPeekMethodReturnsConnect() throws {
        let alicePriv = randomKey()
        let bobPriv = randomKey()
        let bobPubHex = try LightEvent.pubkeyHex(from: bobPriv)
        let bobPubData = Data(hexString: bobPubHex)!

        let request = #"{"id":"req-1","method":"connect","params":["bobpub","secret-xyz"]}"#
        let event = try makeRequestEvent(senderPriv: alicePriv, recipientPub: bobPubData, requestJSON: request)

        let method = LightSigner.peekMethod(privateKey: bobPriv, event: event)
        XCTAssertEqual(method, "connect")
    }

    func testPeekMethodReturnsSignEvent() throws {
        let alicePriv = randomKey()
        let bobPriv = randomKey()
        let bobPubHex = try LightEvent.pubkeyHex(from: bobPriv)
        let bobPubData = Data(hexString: bobPubHex)!

        let request = #"{"id":"req-2","method":"sign_event","params":["{\"kind\":1,\"content\":\"hi\"}"]}"#
        let event = try makeRequestEvent(senderPriv: alicePriv, recipientPub: bobPubData, requestJSON: request)

        let method = LightSigner.peekMethod(privateKey: bobPriv, event: event)
        XCTAssertEqual(method, "sign_event")
    }

    func testPeekMethodReturnsNilForWrongRecipient() throws {
        let alicePriv = randomKey()
        let bobPriv = randomKey()
        let eve = randomKey()
        let bobPubHex = try LightEvent.pubkeyHex(from: bobPriv)
        let bobPubData = Data(hexString: bobPubHex)!

        let request = #"{"id":"req-3","method":"connect","params":[]}"#
        let event = try makeRequestEvent(senderPriv: alicePriv, recipientPub: bobPubData, requestJSON: request)

        let method = LightSigner.peekMethod(privateKey: eve, event: event)
        XCTAssertNil(method)
    }

    func testPeekMethodReturnsNilForMalformedEvent() {
        let bobPriv = randomKey()
        let event: [String: Any] = ["pubkey": "not-hex", "content": "not-valid-b64"]

        let method = LightSigner.peekMethod(privateKey: bobPriv, event: event)
        XCTAssertNil(method)
    }

    func testPeekMethodReturnsNilForMissingFields() {
        let bobPriv = randomKey()
        let event: [String: Any] = [:]

        let method = LightSigner.peekMethod(privateKey: bobPriv, event: event)
        XCTAssertNil(method)
    }
}
