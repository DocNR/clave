import XCTest
@testable import Clave

/// Task 3 of the multi-account sprint (`feat/multi-account`).
///
/// Verifies that adding `signerPubkeyHex` to each persisted record type
/// preserves backwards compatibility for legacy build-31 rows in
/// UserDefaults. Wire format tolerates the missing key via
/// `decodeIfPresent ?? ""`; field type is non-Optional `String`.
///
/// After Task 8 migration runs on first multi-account launch, every row
/// has the field populated. The empty-string state is transient between
/// Codable decode (early in `loadState()`) and the migration backfill
/// (later in the same function, before any view appears).
///
/// Plan: ~/hq/clave/plans/2026-04-30-multi-account-sprint.md
final class MultiAccountRecordCodableTests: XCTestCase {

    // MARK: - ActivityEntry

    func testActivityEntry_decodesLegacyRowWithoutSignerPubkeyHex() throws {
        // Pre-Task 3 wire format — no signerPubkeyHex key in JSON.
        let json = #"""
        {
          "id":"abc","method":"sign_event","eventKind":1,
          "clientPubkey":"client123","timestamp":1714500000,
          "status":"signed","errorMessage":null
        }
        """#
        let entry = try JSONDecoder().decode(ActivityEntry.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(entry.id, "abc")
        XCTAssertEqual(entry.signerPubkeyHex, "",
                       "Legacy row decode should default signerPubkeyHex to empty string")
    }

    func testActivityEntry_roundtripsWithSignerPubkeyHex() throws {
        let entry = ActivityEntry(
            id: "abc", method: "sign_event", eventKind: 1,
            clientPubkey: "c", timestamp: 1, status: "signed", errorMessage: nil,
            signerPubkeyHex: "signer123"
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ActivityEntry.self, from: data)
        XCTAssertEqual(decoded.signerPubkeyHex, "signer123")
        XCTAssertEqual(decoded.id, "abc")
        XCTAssertEqual(decoded.clientPubkey, "c")
    }

    func testActivityEntry_preservesPR19FieldsAlongsideSignerPubkeyHex() throws {
        // Sanity: PR #19's signedEventId / signedSummary / signedReferencedEventId
        // continue to roundtrip alongside the new field.
        let entry = ActivityEntry(
            id: "x", method: "sign_event", eventKind: 7,
            clientPubkey: "c", timestamp: 1, status: "signed", errorMessage: nil,
            signedEventId: "evt-abc",
            signedSummary: "Reacted to e:def",
            signedReferencedEventId: "ref-def",
            signerPubkeyHex: "signer-x"
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ActivityEntry.self, from: data)
        XCTAssertEqual(decoded.signedEventId, "evt-abc")
        XCTAssertEqual(decoded.signedSummary, "Reacted to e:def")
        XCTAssertEqual(decoded.signedReferencedEventId, "ref-def")
        XCTAssertEqual(decoded.signerPubkeyHex, "signer-x")
    }

    // MARK: - PendingRequest

    func testPendingRequest_decodesLegacyRowWithoutSignerPubkeyHex() throws {
        // Pre-Task 3 wire format — no signerPubkeyHex, no responseRelayUrl
        // (build-22 added responseRelayUrl; both Optional/missing-tolerant).
        let json = #"""
        {
          "id":"abc","requestEventJSON":"{}","method":"sign_event",
          "eventKind":1,"clientPubkey":"c","timestamp":1
        }
        """#
        let req = try JSONDecoder().decode(PendingRequest.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(req.id, "abc")
        XCTAssertEqual(req.signerPubkeyHex, "")
        XCTAssertNil(req.responseRelayUrl)
    }

    func testPendingRequest_roundtripsWithSignerPubkeyHex() throws {
        let req = PendingRequest(
            id: "abc", requestEventJSON: "{}", method: "sign_event",
            eventKind: 1, clientPubkey: "c", timestamp: 1,
            responseRelayUrl: "wss://relay.example.com",
            signerPubkeyHex: "signer123"
        )
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(PendingRequest.self, from: data)
        XCTAssertEqual(decoded.signerPubkeyHex, "signer123")
        XCTAssertEqual(decoded.responseRelayUrl, "wss://relay.example.com")
    }

    // MARK: - ConnectedClient

    func testConnectedClient_decodesLegacyRowWithoutSignerPubkeyHex() throws {
        // Legacy row: pre-V2 (no relayUrls) + pre-Task 3 (no signerPubkeyHex).
        let json = #"""
        {
          "pubkey":"abc","name":"Yakihonne",
          "firstSeen":1,"lastSeen":2,"requestCount":3
        }
        """#
        let c = try JSONDecoder().decode(ConnectedClient.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(c.pubkey, "abc")
        XCTAssertEqual(c.signerPubkeyHex, "")
        XCTAssertEqual(c.relayUrls, [])
    }

    func testConnectedClient_roundtripsWithSignerPubkeyHex() throws {
        let c = ConnectedClient(
            pubkey: "abc", name: "test",
            firstSeen: 1, lastSeen: 2, requestCount: 3,
            relayUrls: ["wss://r1"],
            signerPubkeyHex: "signer123"
        )
        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(ConnectedClient.self, from: data)
        XCTAssertEqual(decoded.signerPubkeyHex, "signer123")
        XCTAssertEqual(decoded.relayUrls, ["wss://r1"])
    }

    // MARK: - PairOp

    func testPairOp_decodesLegacyRowWithoutSignerPubkeyHex() throws {
        let json = #"""
        {
          "id":"abc","kind":"pair","clientPubkey":"c",
          "relayUrls":["wss://r1"],"createdAt":1,"failCount":0
        }
        """#
        let op = try JSONDecoder().decode(PairOp.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(op.id, "abc")
        XCTAssertEqual(op.kind, .pair)
        XCTAssertEqual(op.signerPubkeyHex, "")
    }

    func testPairOp_roundtripsWithSignerPubkeyHex() throws {
        let op = PairOp(
            id: "abc", kind: .unpair, clientPubkey: "c",
            relayUrls: nil, createdAt: 1, failCount: 0,
            signerPubkeyHex: "signer123"
        )
        let data = try JSONEncoder().encode(op)
        let decoded = try JSONDecoder().decode(PairOp.self, from: data)
        XCTAssertEqual(decoded.signerPubkeyHex, "signer123")
        XCTAssertEqual(decoded.kind, .unpair)
        XCTAssertNil(decoded.relayUrls)
    }

    // MARK: - ClientPermissions

    func testClientPermissions_decodesLegacyRowWithoutSignerPubkeyHex() throws {
        let json = #"""
        {
          "pubkey":"abc","trustLevel":"full","kindOverrides":{},
          "methodPermissions":["nip04_encrypt"],
          "connectedAt":1,"lastSeen":2,"requestCount":3
        }
        """#
        let p = try JSONDecoder().decode(ClientPermissions.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(p.pubkey, "abc")
        XCTAssertEqual(p.signerPubkeyHex, "")
    }

    func testClientPermissions_roundtripsWithSignerPubkeyHex() throws {
        let p = ClientPermissions(
            pubkey: "abc", trustLevel: .full,
            kindOverrides: [:],
            methodPermissions: ["nip04_encrypt"],
            name: nil, url: nil, imageURL: nil,
            connectedAt: 1, lastSeen: 2, requestCount: 3,
            signerPubkeyHex: "signer123"
        )
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(ClientPermissions.self, from: data)
        XCTAssertEqual(decoded.signerPubkeyHex, "signer123")
        XCTAssertEqual(decoded.pubkey, "abc")
        XCTAssertEqual(decoded.trustLevel, .full)
    }

    // MARK: - ClientPermissions.id (composite)

    func testClientPermissions_idIncludesSignerForCompositeKey() {
        let pA = ClientPermissions(
            pubkey: "client1", trustLevel: .full, kindOverrides: [:], methodPermissions: [],
            name: nil, url: nil, imageURL: nil,
            connectedAt: 0, lastSeen: 0, requestCount: 0,
            signerPubkeyHex: "signerA"
        )
        let pB = ClientPermissions(
            pubkey: "client1", trustLevel: .full, kindOverrides: [:], methodPermissions: [],
            name: nil, url: nil, imageURL: nil,
            connectedAt: 0, lastSeen: 0, requestCount: 0,
            signerPubkeyHex: "signerB"
        )
        // Same client paired with two signers — must produce distinct ids
        // so SwiftUI ForEach renders them as distinct rows.
        XCTAssertNotEqual(pA.id, pB.id)
        XCTAssertEqual(pA.id, "signerA:client1")
        XCTAssertEqual(pB.id, "signerB:client1")
    }

    func testClientPermissions_idFallsBackToPubkey_whenSignerEmpty() {
        // Defensive fallback: a freshly-decoded legacy row (post-decode,
        // pre-migration window) has signerPubkeyHex == "". The id should
        // still produce a stable, sensible value — bare pubkey, matching
        // the pre-multi-account behavior. This window is brief
        // (loadState() backfills before any view runs) but defense in
        // depth keeps SwiftUI ForEach happy if any code path observes
        // the row before backfill.
        let p = ClientPermissions(
            pubkey: "client1", trustLevel: .full, kindOverrides: [:], methodPermissions: [],
            name: nil, url: nil, imageURL: nil,
            connectedAt: 0, lastSeen: 0, requestCount: 0,
            signerPubkeyHex: ""
        )
        XCTAssertEqual(p.id, "client1",
                       "Legacy row id must fall back to bare pubkey, not produce ':client1'")
    }
}
