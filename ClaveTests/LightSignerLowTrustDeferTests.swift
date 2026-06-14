import XCTest
import CryptoKit
@testable import Clave

/// Regression coverage for the NIP-46 low-trust signing bug.
///
/// On **low trust**, `handleRequest` must HOLD a `sign_event` open — queue it
/// and return `"pending"` — rather than emitting a terminal `{ error: ... }`
/// response at prompt-time. Per NIP-46 a populated `error` field "indicates an
/// error with the request" and ends it on the client, so the user's later
/// approval would have no pending request left to satisfy. (Confirmed against
/// the NIP-46 spec and nostr-tools' `BunkerSigner`, which rejects on any
/// `error` that isn't the `result: "auth_url"` Auth-Challenge form.)
///
/// These assertions run fully offline: after the fix the queued-for-approval
/// path makes NO network call (the only one — the prompt-time
/// `sendErrorResponse` — was removed), so driving the real signer end-to-end
/// here is deterministic and fast. Wire-level confirmation (no error on the
/// wire at prompt-time, `{ result }` on approve, `{ error: "user rejected" }`
/// on deny, medium/high unchanged) is covered by the real-relay / `nak`
/// verification, per this project's handleRequest test philosophy.
final class LightSignerLowTrustDeferTests: XCTestCase {

    // Distinct signer + client keypairs (sec = 0x..01 / 0x..02).
    private let signerPriv = Data(hexString: "0000000000000000000000000000000000000000000000000000000000000001")!
    private let clientPriv = Data(hexString: "0000000000000000000000000000000000000000000000000000000000000002")!
    private var signerPub = ""
    private var clientPub = ""

    // Isolated dedupe store so a fixed-created_at request id can't collide with
    // a prior run's processed-event ring.
    private let dedupeKey = "processedEventIDs_lowtrust_defer_test"

    override func setUp() {
        super.setUp()
        SharedStorage._setProcessedEventIDsKeyForTesting(dedupeKey)
        wipe()
        signerPub = try! LightEvent.pubkeyHex(from: signerPriv)
        clientPub = try! LightEvent.pubkeyHex(from: clientPriv)
    }

    override func tearDown() {
        wipe()
        SharedStorage._resetProcessedEventIDsKeyForTesting()
        super.tearDown()
    }

    private func wipe() {
        let d = SharedConstants.sharedDefaults
        d.removeObject(forKey: SharedConstants.pendingRequestsKey)
        d.removeObject(forKey: SharedConstants.clientPermissionsKey)
        d.removeObject(forKey: SharedConstants.connectedClientsKey)
        d.removeObject(forKey: SharedConstants.activityLogKey)
        d.removeObject(forKey: dedupeKey)
    }

    /// Pair `clientPub` → `signerPub` at the given trust level so the
    /// permission gate in handleRequest finds a row.
    private func seedClient(trust: TrustLevel) {
        let perms = ClientPermissions(
            pubkey: clientPub, trustLevel: trust, kindOverrides: [:],
            methodPermissions: ClientPermissions.defaultMethodPermissions,
            name: "Test Client", url: nil, imageURL: nil,
            connectedAt: Date().timeIntervalSince1970,
            lastSeen: Date().timeIntervalSince1970,
            requestCount: 0, signerPubkeyHex: signerPub)
        SharedStorage.saveClientPermissions(perms)
        SharedStorage.setClientRelayUrls(
            pubkey: clientPub, relayUrls: [SharedConstants.relayURL], signer: signerPub)
    }

    /// Build a valid, signed + NIP-44-encrypted kind:24133 `sign_event`
    /// request from the client to the signer. Passes `LightEvent.verify`
    /// (real Schnorr sig) and decrypts cleanly inside handleRequest.
    private func makeSignEventRequest(requestId: String, kind: Int) throws -> [String: Any] {
        let toSignObj: [String: Any] = [
            "kind": kind, "content": "hello", "tags": [], "created_at": 1714078911,
        ]
        let toSign = String(
            data: try JSONSerialization.data(withJSONObject: toSignObj), encoding: .utf8)!
        let rpc: [String: Any] = ["id": requestId, "method": "sign_event", "params": [toSign]]
        let rpcJSON = String(
            data: try JSONSerialization.data(withJSONObject: rpc), encoding: .utf8)!
        let encrypted = try LightCrypto.nip44Encrypt(
            privateKey: clientPriv, publicKey: Data(hexString: signerPub)!, plaintext: rpcJSON)
        let event = try LightEvent.sign(
            privateKey: clientPriv, kind: 24133, content: encrypted, tags: [["p", signerPub]])
        return event.toDict()
    }

    /// THE regression: a low-trust sign_event is queued and held "pending",
    /// not terminally errored. Pre-fix this path also published a terminal
    /// `{ error: "Permission denied — open Clave to approve" }` to the wire,
    /// which made every NIP-46 client give up before the user could approve.
    func test_lowTrust_signEvent_isHeldPending_andQueued() async throws {
        seedClient(trust: .low)
        let req = try makeSignEventRequest(requestId: "req-low-1", kind: 1)

        let result = try await LightSigner.handleRequest(
            privateKey: signerPriv, requestEvent: req)

        XCTAssertEqual(result.status, "pending",
                       "low-trust sign_event must be held pending — not resolved with an error")
        XCTAssertEqual(result.method, "sign_event")
        XCTAssertEqual(result.eventKind, 1)
        XCTAssertNotNil(result.pendingRequestId,
                        "a pending id must be issued so approve/deny can resolve the held request")

        let queued = SharedStorage.getPendingRequests()
        XCTAssertEqual(queued.count, 1, "exactly one pending request must be queued")
        XCTAssertEqual(queued.first?.method, "sign_event")
        XCTAssertEqual(queued.first?.eventKind, 1)
        XCTAssertEqual(queued.first?.clientPubkey, clientPub)
        XCTAssertEqual(queued.first?.signerPubkeyHex, signerPub,
                       "queued request must record the receiving signer so approve/deny sign as the right account")
    }
}
