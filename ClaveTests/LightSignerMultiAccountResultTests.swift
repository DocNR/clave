import XCTest
@testable import Clave

/// Tests for LightSigner.connectAckResult(...) — the per-ack `result`
/// field builder. Single-account path emits bare-string secret;
/// multi-account path emits JSON {echoed_secret, name?, picture?, total}.
final class LightSignerMultiAccountResultTests: XCTestCase {

    func testSingleAccount_isBareSecret() {
        // Single-account flow (isMultiAccount: false) emits the existing
        // string-secret format — preserves backwards compat for every
        // existing client, including those that string-compare result.
        let result = LightSigner.connectAckResult(
            isMultiAccount: false,
            echoedSecret: "abc123",
            accountName: "alice",
            accountPicture: "https://example.com/p.png",
            total: 1
        )
        XCTAssertEqual(result, "abc123")
    }

    func testMultiAccount_isJSON_withAllFields() throws {
        let result = LightSigner.connectAckResult(
            isMultiAccount: true,
            echoedSecret: "abc123",
            accountName: "alice",
            accountPicture: "https://example.com/p.png",
            total: 3
        )
        let json = try parseJSONObject(result)
        XCTAssertEqual(json["echoed_secret"] as? String, "abc123")
        XCTAssertEqual(json["name"] as? String, "alice")
        XCTAssertEqual(json["picture"] as? String, "https://example.com/p.png")
        XCTAssertEqual(json["total"] as? Int, 3)
    }

    func testMultiAccount_omitsNilName() throws {
        let result = LightSigner.connectAckResult(
            isMultiAccount: true,
            echoedSecret: "abc123",
            accountName: nil,
            accountPicture: "https://example.com/p.png",
            total: 2
        )
        let json = try parseJSONObject(result)
        XCTAssertEqual(json["echoed_secret"] as? String, "abc123")
        XCTAssertNil(json["name"])
        XCTAssertEqual(json["picture"] as? String, "https://example.com/p.png")
        XCTAssertEqual(json["total"] as? Int, 2)
    }

    func testMultiAccount_omitsNilPicture() throws {
        let result = LightSigner.connectAckResult(
            isMultiAccount: true,
            echoedSecret: "abc123",
            accountName: "alice",
            accountPicture: nil,
            total: 2
        )
        let json = try parseJSONObject(result)
        XCTAssertEqual(json["echoed_secret"] as? String, "abc123")
        XCTAssertEqual(json["name"] as? String, "alice")
        XCTAssertNil(json["picture"])
        XCTAssertEqual(json["total"] as? Int, 2)
    }

    func testMultiAccount_omitsEmptyName() throws {
        // Empty-string name is treated identically to nil — no point
        // emitting `"name": ""` for a client.
        let result = LightSigner.connectAckResult(
            isMultiAccount: true,
            echoedSecret: "abc123",
            accountName: "",
            accountPicture: nil,
            total: 1
        )
        let json = try parseJSONObject(result)
        XCTAssertNil(json["name"])
        XCTAssertEqual(json["total"] as? Int, 1)
    }

    func testMultiAccount_totalAlwaysPresent() throws {
        // Even with name + picture both nil, `total` is always emitted —
        // Spectr's accumulator uses it for auto-finalize.
        let result = LightSigner.connectAckResult(
            isMultiAccount: true,
            echoedSecret: "abc123",
            accountName: nil,
            accountPicture: nil,
            total: 5
        )
        let json = try parseJSONObject(result)
        XCTAssertEqual(json["echoed_secret"] as? String, "abc123")
        XCTAssertEqual(json["total"] as? Int, 5)
    }

    // MARK: - Helpers

    private func parseJSONObject(_ str: String) throws -> [String: Any] {
        guard let data = str.data(using: .utf8) else {
            XCTFail("Result is not utf8")
            return [:]
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Result is not a JSON object: \(str)")
            return [:]
        }
        return obj
    }
}
