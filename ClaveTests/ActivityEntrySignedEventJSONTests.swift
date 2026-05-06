import XCTest
@testable import Clave

/// Verifies the `signedEventJSON` field added to `ActivityEntry` for
/// the activity-detail "View raw event" disclosure:
/// - Forward Codable round-trip with the field populated
/// - Backward decode of legacy JSON missing the field (must default
///   to nil without throwing)
/// - Nil round-trip when not provided (encrypt/decrypt/error/expired
///   entries should not carry a raw event)
final class ActivityEntrySignedEventJSONTests: XCTestCase {

    func test_codableRoundTrip_withSignedEventJSON_populated() throws {
        let json = #"{"id":"abc","kind":1,"content":"hello"}"#
        let entry = ActivityEntry(
            id: "1",
            method: "sign_event",
            eventKind: 1,
            clientPubkey: "client",
            timestamp: 100,
            status: "signed",
            errorMessage: nil,
            signedEventId: "abc",
            signedSummary: "hello",
            signedReferencedEventId: nil,
            signedEventJSON: json,
            signerPubkeyHex: "signer"
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ActivityEntry.self, from: data)
        XCTAssertEqual(decoded.signedEventJSON, json)
    }

    func test_codableDecode_legacyRowWithoutSignedEventJSON() throws {
        // Wire-format snapshot from a pre-this-sprint persisted row.
        // No `signedEventJSON` key — must decode with the field nil.
        let legacyJSON = """
        {
          "id": "legacy-1",
          "method": "sign_event",
          "eventKind": 1,
          "clientPubkey": "client",
          "timestamp": 1,
          "status": "signed",
          "errorMessage": null,
          "signedEventId": "abc",
          "signedSummary": "hello",
          "signedReferencedEventId": null,
          "signerPubkeyHex": "signer"
        }
        """
        let data = legacyJSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ActivityEntry.self, from: data)
        XCTAssertNil(decoded.signedEventJSON,
                     "Legacy rows without the new key must decode to nil — backward compat")
        XCTAssertEqual(decoded.signedEventId, "abc",
                       "Other fields must still decode normally")
    }

    func test_defaultInit_signedEventJSONIsNil() {
        // The convenience init's default for `signedEventJSON` is nil —
        // verifies that error/blocked/connect/encrypt/decrypt/expired
        // call sites that don't pass the field (existing AppState.swift
        // ActivityEntry constructions, for instance) get nil, not a
        // misleading default.
        let entry = ActivityEntry(
            id: "1",
            method: "connect",
            eventKind: nil,
            clientPubkey: "client",
            timestamp: 1,
            status: "error",
            errorMessage: "no relay"
        )
        XCTAssertNil(entry.signedEventJSON)
    }

    func test_codableRoundTrip_signedEventJSONNil() throws {
        // Round-trip with the field intentionally nil — the encoded
        // form may write null OR omit the key (synthesized vs explicit
        // encode), but decode must recover it as nil.
        let entry = ActivityEntry(
            id: "1",
            method: "sign_event",
            eventKind: 1,
            clientPubkey: "client",
            timestamp: 1,
            status: "blocked",
            errorMessage: "denied",
            signedEventJSON: nil
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ActivityEntry.self, from: data)
        XCTAssertNil(decoded.signedEventJSON)
    }
}
