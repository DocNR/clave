import XCTest
@testable import Clave

final class AppStateHandshakeSignatureTests: XCTestCase {

    func testHandleNostrConnectSignatureCompiles() {
        let _: (NostrConnectParser.ParsedURI, [String], ClientPermissions) async throws -> HandshakeResult =
            { (uri, pks, perms) in
                let appState = AppState()
                return try await appState.handleNostrConnect(
                    parsedURI: uri,
                    signerPubkeys: pks,
                    permissions: perms
                )
            }
    }

    func testEmptySignerPubkeysThrows() async throws {
        let appState = await AppState()
        let dummyURI = try NostrConnectParser.parse(
            "nostrconnect://abc?relay=wss%3A%2F%2Frelay.example.com&secret=s"
        )
        let perms = ClientPermissions(
            pubkey: "abc",
            trustLevel: .medium,
            kindOverrides: [:],
            methodPermissions: ClientPermissions.defaultMethodPermissions,
            name: nil,
            connectedAt: Date().timeIntervalSince1970,
            lastSeen: Date().timeIntervalSince1970,
            requestCount: 0,
            signerPubkeyHex: ""
        )
        do {
            _ = try await appState.handleNostrConnect(
                parsedURI: dummyURI,
                signerPubkeys: [],
                permissions: perms
            )
            XCTFail("Expected ClaveError.noSignerKey for empty signerPubkeys")
        } catch ClaveError.noSignerKey {
            // expected
        } catch {
            XCTFail("Expected ClaveError.noSignerKey, got \(error)")
        }
    }
}
