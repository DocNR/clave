import Foundation
import os.log

private let logger = Logger(subsystem: "dev.nostr.clave", category: "signer")

enum LightSigner {

    static func handleRequest(privateKey: Data, requestEvent: [String: Any]) async throws {
        guard let senderPubkey = requestEvent["pubkey"] as? String,
              let encryptedContent = requestEvent["content"] as? String else {
            logger.error("[LightSigner] Invalid event: missing pubkey or content")
            return
        }

        guard let senderPubkeyData = Data(hexString: senderPubkey) else {
            logger.error("[LightSigner] Invalid sender pubkey hex")
            return
        }

        let isNip04 = encryptedContent.contains("?iv=")
        let decrypted: String
        do {
            decrypted = try LightCrypto.decrypt(
                privateKey: privateKey,
                publicKey: senderPubkeyData,
                payload: encryptedContent
            )
        } catch {
            logger.error("[LightSigner] Decrypt failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard let data = decrypted.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requestId = json["id"] as? String,
              let method = json["method"] as? String else {
            logger.error("[LightSigner] Failed to parse JSON-RPC")
            return
        }

        let params = json["params"] as? [String] ?? []
        logger.notice("[LightSigner] Method: \(method, privacy: .public)")

        let (result, error) = processRequest(method: method, params: params, privateKey: privateKey)

        var responseDict: [String: Any] = ["id": requestId]
        if let result = result {
            responseDict["result"] = result
        }
        if let error = error {
            responseDict["error"] = error
        }

        guard let responseData = try? JSONSerialization.data(withJSONObject: responseDict),
              let responseJSON = String(data: responseData, encoding: .utf8) else {
            logger.error("[LightSigner] Failed to serialize response")
            return
        }

        // Respond with same encryption the client used
        let encryptedResponse: String
        if isNip04 {
            encryptedResponse = try LightCrypto.nip04Encrypt(
                privateKey: privateKey,
                publicKey: senderPubkeyData,
                plaintext: responseJSON
            )
        } else {
            encryptedResponse = try LightCrypto.nip44Encrypt(
                privateKey: privateKey,
                publicKey: senderPubkeyData,
                plaintext: responseJSON
            )
        }

        let responseEvent = try LightEvent.sign(
            privateKey: privateKey,
            kind: 24133,
            content: encryptedResponse,
            tags: [["p", senderPubkey]]
        )

        let relay = LightRelay(url: SharedConstants.relayURL)
        try await relay.connect(timeout: 5.0)

        let eventJSON = responseEvent.toJSON()
        guard let eventData = eventJSON.data(using: .utf8),
              let eventDict = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any] else {
            logger.error("[LightSigner] Failed to serialize event for publish")
            relay.disconnect()
            return
        }

        let accepted = try await relay.publishEvent(event: eventDict)
        if accepted {
            logger.notice("[LightSigner] Response published successfully")
        } else {
            logger.error("[LightSigner] Relay did not accept response event")
        }
        relay.disconnect()
    }

    private static func processRequest(method: String, params: [String], privateKey: Data) -> (String?, String?) {
        switch method {
        case "ping":
            return ("pong", nil)

        case "get_public_key":
            do {
                let pubkey = try LightEvent.pubkeyHex(from: privateKey)
                return (pubkey, nil)
            } catch {
                return (nil, "Failed to derive pubkey: \(error.localizedDescription)")
            }

        case "sign_event":
            guard let eventJson = params.first else {
                return (nil, "Missing event parameter")
            }
            do {
                let signed = try LightEvent.signUnsignedEvent(privateKey: privateKey, unsignedJSON: eventJson)
                return (signed.toJSON(), nil)
            } catch {
                return (nil, "Sign failed: \(error.localizedDescription)")
            }

        case "connect":
            // Return the secret if provided in params
            if params.count >= 2, !params[1].isEmpty {
                return (params[1], nil)
            }
            return ("ack", nil)

        case "describe":
            return ("[\"connect\",\"sign_event\",\"get_public_key\",\"ping\",\"describe\"]", nil)

        default:
            return (nil, "Unsupported method: \(method)")
        }
    }
}
