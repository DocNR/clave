import XCTest
import CryptoKit
@testable import Clave

/// Wire-level smoke for the NIP-46 low-trust fix. Unlike the offline
/// `LightSignerLowTrustDeferTests`, this drives Clave's REAL publish code and
/// emits the resulting kind:24133 responses onto a relay so they can be
/// inspected on the wire with `nak`.
///
/// Self-gating: it probes `ws://localhost:10547` and XCTSkips unless a relay
/// is listening there (e.g. `nak serve`), so it's a clean skip in normal
/// suite runs and only does real work under the orchestrator
/// `research/nip46-lowtrust-wire-smoke/run.sh`, which starts the relay, runs
/// this test, then fetches + decrypts the responses with `nak` and asserts:
///   • held-open  → NO response on the wire (request id "wire-held-1" absent)
///   • approve    → { id:"wire-approve-1", result:<signed_event> }  (no error)
///   • deny       → { id:"wire-deny-1",    error:"user rejected" }
///
/// Keys are fixed so the orchestrator can decrypt:
///   signer sec=0x..01  pub=79be667e…f81798
///   client sec=0x..02  pub=c6047f94…709ee5
final class LightSignerWireSmokeTests: XCTestCase {

    private let signerPriv = Data(hexString: "0000000000000000000000000000000000000000000000000000000000000001")!
    private let clientPriv = Data(hexString: "0000000000000000000000000000000000000000000000000000000000000002")!
    private var signerPub = ""
    private var clientPub = ""
    private let dedupeKey = "processedEventIDs_wire_smoke_test"

    // Fixed local relay (matches run.sh's `nak serve --port 10547`).
    private let relayURL = "ws://localhost:10547"

    /// XCTSkip unless a relay is actually listening on `relayURL`. Connection
    /// is refused near-instantly when `nak serve` isn't up, so normal suite
    /// runs skip this test fast instead of attempting real publishes.
    private func skipUnlessRelayUp() async throws {
        let probe = LightRelay(url: relayURL)
        do {
            try await probe.connect(timeout: 2.0)
            probe.disconnect()
        } catch {
            throw XCTSkip("no relay on \(relayURL) — wire smoke runs via run.sh")
        }
    }

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

    private func seedLowTrustClient() {
        let perms = ClientPermissions(
            pubkey: clientPub, trustLevel: .low, kindOverrides: [:],
            methodPermissions: ClientPermissions.defaultMethodPermissions,
            name: "Wire Smoke Client", url: nil, imageURL: nil,
            connectedAt: Date().timeIntervalSince1970,
            lastSeen: Date().timeIntervalSince1970,
            requestCount: 0, signerPubkeyHex: signerPub)
        SharedStorage.saveClientPermissions(perms)
        SharedStorage.setClientRelayUrls(
            pubkey: clientPub, relayUrls: [relayURL], signer: signerPub)
    }

    private func makeSignEventRequest(requestId: String, kind: Int) throws -> [String: Any] {
        let toSignObj: [String: Any] = [
            "kind": kind, "content": "wire smoke", "tags": [], "created_at": 1714078911,
        ]
        let toSign = String(data: try JSONSerialization.data(withJSONObject: toSignObj), encoding: .utf8)!
        let rpc: [String: Any] = ["id": requestId, "method": "sign_event", "params": [toSign]]
        let rpcJSON = String(data: try JSONSerialization.data(withJSONObject: rpc), encoding: .utf8)!
        let encrypted = try LightCrypto.nip44Encrypt(
            privateKey: clientPriv, publicKey: Data(hexString: signerPub)!, plaintext: rpcJSON)
        let event = try LightEvent.sign(
            privateKey: clientPriv, kind: 24133, content: encrypted, tags: [["p", signerPub]])
        return event.toDict()
    }

    /// Publishes the three outcomes to CLAVE_WIRE_RELAY. The wire assertions
    /// happen in the orchestrator via `nak`; here we only confirm Clave's
    /// return-value contract (which also proves the relay publish succeeded).
    func test_wireSmoke_publishesHeldApproveDeny() async throws {
        try await skipUnlessRelayUp()
        seedLowTrustClient()

        // 1) HELD-OPEN — low trust, no skipProtection → queue, publish nothing.
        let held = try makeSignEventRequest(requestId: "wire-held-1", kind: 1)
        let heldResult = try await LightSigner.handleRequest(
            privateKey: signerPriv, requestEvent: held, responseRelayUrl: relayURL)
        XCTAssertEqual(heldResult.status, "pending",
                       "held-open request must NOT publish a response (pending only)")

        // 2) APPROVE — replay with skipProtection+skipDedupe (exactly what
        //    AppState.performApprove does) → publishes { result: <signed> }.
        let approve = try makeSignEventRequest(requestId: "wire-approve-1", kind: 1)
        let approveResult = try await LightSigner.handleRequest(
            privateKey: signerPriv, requestEvent: approve,
            skipProtection: true, skipDedupe: true, responseRelayUrl: relayURL)
        XCTAssertEqual(approveResult.status, "signed",
                       "approve must sign and publish a {result} response to the relay")

        // 3) DENY — sendRejection recovers the id and publishes { error }.
        let deny = try makeSignEventRequest(requestId: "wire-deny-1", kind: 1)
        let denyJSON = String(data: try JSONSerialization.data(withJSONObject: deny), encoding: .utf8)!
        await LightSigner.sendRejection(
            privateKey: signerPriv, requestEventJSON: denyJSON, responseRelayUrl: relayURL)
        // No return value to assert; the orchestrator verifies the wire event.
    }
}
