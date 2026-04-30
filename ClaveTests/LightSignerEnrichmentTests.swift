import XCTest
@testable import Clave

/// Tests for `LightSigner.extractSignedEventEnrichment` — the enrichment
/// helper that pulls the resulting event id, builds the activity summary,
/// and (for wrapper kinds) extracts the referenced event id from a
/// successful sign_event response. Pure logic, no I/O outside the kind:3
/// snapshot path which we exercise via SharedStorage in a separate test.
final class LightSignerEnrichmentTests: XCTestCase {

    // MARK: - Referenced event id (the kind:7 njump fix)

    func testKind1NoReferencedEventId() {
        let json = signedEventJSON(kind: 1, tags: [
            ["e", "abc123def456789012345678901234567890123456789012345678901234abcd"]
        ])
        let result = LightSigner.extractSignedEventEnrichment(signedEventJSON: json)
        XCTAssertNotNil(result.eventId)
        XCTAssertNil(result.referencedEventId, "kind:1 is not a wrapper kind — referenced id should be nil even when an e tag exists")
    }

    func testKind7ExtractsReferencedEventIdFromETag() {
        let target = "abc123def456789012345678901234567890123456789012345678901234abcd"
        let json = signedEventJSON(kind: 7, tags: [
            ["e", target],
            ["p", "alice56789012345678901234567890123456789012345678901234567890aaaa"]
        ])
        let result = LightSigner.extractSignedEventEnrichment(signedEventJSON: json)
        XCTAssertEqual(result.referencedEventId, target)
        XCTAssertNotEqual(result.eventId, result.referencedEventId, "signed wrapper id and referenced id must be distinct")
    }

    func testKind6RepostExtractsReferencedEventId() {
        let target = "def4567890123456789012345678901234567890123456789012345678901234"
        let json = signedEventJSON(kind: 6, tags: [["e", target]])
        let result = LightSigner.extractSignedEventEnrichment(signedEventJSON: json)
        XCTAssertEqual(result.referencedEventId, target)
    }

    func testKind9734ZapRequestExtractsReferencedEventId() {
        let target = "1234567890123456789012345678901234567890123456789012345678901234"
        let json = signedEventJSON(kind: 9734, tags: [
            ["p", "alice56789012345678901234567890123456789012345678901234567890aaaa"],
            ["e", target]
        ])
        let result = LightSigner.extractSignedEventEnrichment(signedEventJSON: json)
        XCTAssertEqual(result.referencedEventId, target)
    }

    func testKind7WithoutETagReturnsNilReferencedEventId() {
        let json = signedEventJSON(kind: 7, tags: [
            ["p", "alice56789012345678901234567890123456789012345678901234567890aaaa"]
        ])
        let result = LightSigner.extractSignedEventEnrichment(signedEventJSON: json)
        XCTAssertNil(result.referencedEventId, "no e tag — referenced id should be nil so view can hide the njump button")
    }

    func testKind7RejectsMalformedETag() {
        // 64-char hex is required — short or non-hex values must be rejected
        // so we never feed garbage to Nip19.encodeNote in the view layer.
        let json = signedEventJSON(kind: 7, tags: [["e", "abc"]])
        let result = LightSigner.extractSignedEventEnrichment(signedEventJSON: json)
        XCTAssertNil(result.referencedEventId)
    }

    func testKind7RejectsNonHexETag() {
        let nonHex = String(repeating: "z", count: 64)
        let json = signedEventJSON(kind: 7, tags: [["e", nonHex]])
        let result = LightSigner.extractSignedEventEnrichment(signedEventJSON: json)
        XCTAssertNil(result.referencedEventId)
    }

    func testWrapperKindsContainsExpectedSet() {
        XCTAssertEqual(LightSigner.wrapperKinds, [6, 7, 9734, 9735])
    }

    // MARK: - Event id + summary basics

    func testReturnsNilForMalformedJSON() {
        let result = LightSigner.extractSignedEventEnrichment(signedEventJSON: "not json")
        XCTAssertNil(result.eventId)
        XCTAssertNil(result.summary)
        XCTAssertNil(result.referencedEventId)
    }

    func testEventIdRoundTripsFromJSON() {
        let id = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
        let json = signedEventJSON(kind: 1, tags: [], idOverride: id)
        let result = LightSigner.extractSignedEventEnrichment(signedEventJSON: json)
        XCTAssertEqual(result.eventId, id)
    }

    func testSummaryBuiltFromKindAndTags() {
        let json = signedEventJSON(kind: 1, tags: [
            ["t", "nostr"]
        ])
        let result = LightSigner.extractSignedEventEnrichment(signedEventJSON: json)
        XCTAssertEqual(result.summary, "New note · #nostr")
    }

    // MARK: - Helpers

    private func signedEventJSON(
        kind: Int,
        tags: [[String]],
        idOverride: String? = nil
    ) -> String {
        let id = idOverride ?? "0000000000000000000000000000000000000000000000000000000000000000"
        let dict: [String: Any] = [
            "id": id,
            "kind": kind,
            "tags": tags,
            "content": "",
            "pubkey": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
            "created_at": 1714003200,
            "sig": "deadbeef"
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return String(data: data, encoding: .utf8)!
    }
}
