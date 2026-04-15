import Foundation
import CryptoKit
import P256K

struct LightNostrEvent {
    let id: String
    let pubkey: String
    let createdAt: Int
    let kind: Int
    let tags: [[String]]
    let content: String
    let sig: String

    func toJSON() -> String {
        let tagsJSON = tags.map { tag in
            "[" + tag.map { "\"\(escapeJSON($0))\"" }.joined(separator: ",") + "]"
        }.joined(separator: ",")

        return "{\"id\":\"\(id)\",\"pubkey\":\"\(pubkey)\",\"created_at\":\(createdAt),\"kind\":\(kind),\"tags\":[\(tagsJSON)],\"content\":\"\(escapeJSON(content))\",\"sig\":\"\(sig)\"}"
    }

    private func escapeJSON(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
           .replacingOccurrences(of: "\n", with: "\\n")
           .replacingOccurrences(of: "\r", with: "\\r")
           .replacingOccurrences(of: "\t", with: "\\t")
    }
}

enum LightEvent {

    static func pubkeyHex(from privateKey: Data) throws -> String {
        let privKey = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
        return Data(privKey.xonly.bytes).hex
    }

    static func sign(privateKey: Data, kind: Int, content: String, tags: [[String]], createdAt: Int? = nil) throws -> LightNostrEvent {
        let privKey = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
        let pubkeyHex = Data(privKey.xonly.bytes).hex
        let ts = createdAt ?? Int(Date().timeIntervalSince1970)

        let tagsJSON = tags.map { tag in
            "[" + tag.map { "\"\(escapeJSON($0))\"" }.joined(separator: ",") + "]"
        }.joined(separator: ",")

        let serialized = "[0,\"\(pubkeyHex)\",\(ts),\(kind),[\(tagsJSON)],\"\(escapeJSON(content))\"]"
        let idHash = CryptoKit.SHA256.hash(data: Data(serialized.utf8))
        let idData = Data(idHash)
        let idHex = idData.hex

        var idBytes = Array(idData)
        var auxRand = try Array(generateAuxRand())
        let signature = try privKey.signature(message: &idBytes, auxiliaryRand: &auxRand, strict: true)
        let sigHex = signature.dataRepresentation.hex

        return LightNostrEvent(
            id: idHex,
            pubkey: pubkeyHex,
            createdAt: ts,
            kind: kind,
            tags: tags,
            content: content,
            sig: sigHex
        )
    }

    /// Build a NIP-98 (kind 27235) HTTP auth event and return it base64-encoded inside an `Authorization: Nostr <base64>` header string.
    static func signNip98(
        privateKey: Data,
        url: String,
        method: String,
        bodySha256Hex: String?
    ) throws -> String {
        var tags: [[String]] = [
            ["u", url],
            ["method", method],
        ]
        if let hash = bodySha256Hex, !hash.isEmpty {
            tags.append(["payload", hash])
        }

        let event = try sign(
            privateKey: privateKey,
            kind: 27235,
            content: "",
            tags: tags
        )

        let eventJSON = event.toJSON()
        guard let eventData = eventJSON.data(using: .utf8) else {
            throw LightEventError.invalidUnsignedEvent
        }
        let b64 = eventData.base64EncodedString()
        return "Nostr \(b64)"
    }

    static func signUnsignedEvent(privateKey: Data, unsignedJSON: String) throws -> LightNostrEvent {
        guard let data = unsignedJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = json["kind"] as? Int,
              let content = json["content"] as? String else {
            throw LightEventError.invalidUnsignedEvent
        }

        let tags: [[String]]
        if let rawTags = json["tags"] as? [[Any]] {
            tags = rawTags.map { $0.map { "\($0)" } }
        } else {
            tags = []
        }

        let createdAt = json["created_at"] as? Int

        return try sign(privateKey: privateKey, kind: kind, content: content, tags: tags, createdAt: createdAt)
    }

    private static func escapeJSON(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
           .replacingOccurrences(of: "\n", with: "\\n")
           .replacingOccurrences(of: "\r", with: "\\r")
           .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func generateAuxRand() throws -> Data {
        var randBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &randBytes) == errSecSuccess else {
            throw LightEventError.randomFailed
        }
        return Data(randBytes)
    }
}

enum LightEventError: LocalizedError {
    case invalidUnsignedEvent
    case randomFailed

    var errorDescription: String? {
        switch self {
        case .invalidUnsignedEvent: return "Invalid unsigned event JSON"
        case .randomFailed: return "Failed to generate random bytes"
        }
    }
}

extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        let len = hexString.count
        guard len % 2 == 0 else { return nil }
        var data = Data(capacity: len / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
