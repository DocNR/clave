import XCTest
import CryptoKit
@testable import Clave

final class LightEventNip98Tests: XCTestCase {

    private let testPrivateKey = Data(hexString: "0000000000000000000000000000000000000000000000000000000000000001")!

    func test_signNip98_producesBase64EncodedKind27235Event() throws {
        let url = "https://proxy.clave.casa/register"
        let method = "POST"
        let bodyHash = "a591a6d40bf420404a011733cfb7b190d62c65bf0bcda32b57b277d9ad9f146e"

        let authHeader = try LightEvent.signNip98(
            privateKey: testPrivateKey,
            url: url,
            method: method,
            bodySha256Hex: bodyHash
        )

        XCTAssertTrue(authHeader.hasPrefix("Nostr "), "Header should use Nostr scheme")

        let b64 = String(authHeader.dropFirst("Nostr ".count))
        guard let eventData = Data(base64Encoded: b64),
              let json = try JSONSerialization.jsonObject(with: eventData) as? [String: Any] else {
            XCTFail("Failed to decode auth header")
            return
        }

        XCTAssertEqual(json["kind"] as? Int, 27235, "Must be kind 27235")
        XCTAssertEqual((json["content"] as? String) ?? "missing", "", "Content must be empty")

        guard let tags = json["tags"] as? [[String]] else {
            XCTFail("Tags must be [[String]]")
            return
        }

        let uTag = tags.first { $0.first == "u" }
        XCTAssertEqual(uTag?[1], url)

        let methodTag = tags.first { $0.first == "method" }
        XCTAssertEqual(methodTag?[1], method)

        let payloadTag = tags.first { $0.first == "payload" }
        XCTAssertEqual(payloadTag?[1], bodyHash)

        XCTAssertNotNil(json["sig"] as? String)
        XCTAssertNotNil(json["id"] as? String)
        XCTAssertNotNil(json["pubkey"] as? String)
    }

    func test_signNip98_omitsPayloadTagWhenBodyHashIsNil() throws {
        let authHeader = try LightEvent.signNip98(
            privateKey: testPrivateKey,
            url: "https://proxy.clave.casa/register",
            method: "GET",
            bodySha256Hex: nil
        )

        let b64 = String(authHeader.dropFirst("Nostr ".count))
        let eventData = Data(base64Encoded: b64)!
        let json = try JSONSerialization.jsonObject(with: eventData) as! [String: Any]
        let tags = json["tags"] as! [[String]]

        XCTAssertNil(tags.first { $0.first == "payload" }, "Payload tag should be absent when hash is nil")
    }

    func test_signNip98_createdAtIsRecent() throws {
        let before = Int(Date().timeIntervalSince1970)
        let authHeader = try LightEvent.signNip98(
            privateKey: testPrivateKey,
            url: "https://proxy.clave.casa/register",
            method: "POST",
            bodySha256Hex: nil
        )
        let after = Int(Date().timeIntervalSince1970)

        let b64 = String(authHeader.dropFirst("Nostr ".count))
        let eventData = Data(base64Encoded: b64)!
        let json = try JSONSerialization.jsonObject(with: eventData) as! [String: Any]
        let createdAt = json["created_at"] as! Int

        XCTAssertGreaterThanOrEqual(createdAt, before)
        XCTAssertLessThanOrEqual(createdAt, after + 1)
    }
}
