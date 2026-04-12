import Foundation
import NostrSDK
import os.log

private let logger = Logger(subsystem: "dev.nostr.clave", category: "signer")

enum SignerService {

    /// Load signer Keys from shared Keychain
    static func loadSignerKeys() throws -> Keys {
        guard let nsec = SharedKeychain.loadNsec() else {
            throw SignerError.noKeyFound
        }
        return try Keys.parse(secretKey: nsec)
    }

    /// Handle a NIP-46 request: decrypt, process, build response, publish
    static func handleRequest(
        signerKeys: Keys,
        requestEvent: Event
    ) async throws {
        let clientPubkey = requestEvent.author()

        // Decrypt the NIP-44 content
        let decrypted = try nip44Decrypt(
            secretKey: signerKeys.secretKey(),
            publicKey: clientPubkey,
            payload: requestEvent.content()
        )

        // Parse JSON-RPC request
        guard let data = decrypted.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requestId = json["id"] as? String,
              let method = json["method"] as? String else {
            logger.notice("[SignerService] Failed to parse NIP-46 request JSON")
            return
        }

        let params = json["params"] as? [String] ?? []
        logger.notice("[SignerService] Request: method=\(method) id=\(requestId)")

        // Process the request
        let (result, error) = processRequest(
            method: method,
            params: params,
            signerKeys: signerKeys
        )

        // Build response (NIP-44 encryption handled internally by nostrConnect)
        let responseMsg = NostrConnectMessage.response(
            id: requestId,
            result: result,
            error: error
        )

        let builder = try EventBuilder.nostrConnect(
            senderKeys: signerKeys,
            receiverPubkey: clientPubkey,
            msg: responseMsg
        )

        // Publish response
        let signer = NostrSigner.keys(keys: signerKeys)
        let client = Client(signer: signer)
        let relayUrl = try RelayUrl.parse(url: SharedConstants.relayURL)
        _ = try await client.addRelay(url: relayUrl)
        await client.connect()
        await client.waitForConnection(timeout: 5.0)

        let output = try await client.sendEventBuilder(builder: builder)
        logger.notice("[SignerService] Response published: \(output.id.toHex())")

        await client.disconnect()
    }

    private static func processRequest(
        method: String,
        params: [String],
        signerKeys: Keys
    ) -> (String?, String?) {
        switch method {
        case "ping":
            return ("pong", nil)

        case "get_public_key":
            return (signerKeys.publicKey().toHex(), nil)

        case "sign_event":
            guard let eventJson = params.first else {
                return (nil, "Missing event parameter")
            }
            do {
                let unsigned = try UnsignedEvent.fromJson(json: eventJson)
                let signed = try unsigned.signWithKeys(keys: signerKeys)
                let signedJson = try signed.asJson()
                return (signedJson, nil)
            } catch {
                return (nil, "Sign failed: \(error.localizedDescription)")
            }

        case "connect":
            return ("ack", nil)

        default:
            return (nil, "Unsupported method: \(method)")
        }
    }
}

enum SignerError: LocalizedError {
    case noKeyFound

    var errorDescription: String? {
        switch self {
        case .noKeyFound: return "No signer key found in shared Keychain"
        }
    }
}
