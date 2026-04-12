import Foundation
import CryptoKit
import CommonCrypto
import P256K

enum LightCrypto {

    // MARK: - Auto-detect NIP-04 vs NIP-44

    static func decrypt(privateKey: Data, publicKey: Data, payload: String) throws -> String {
        if payload.contains("?iv=") {
            return try nip04Decrypt(privateKey: privateKey, publicKey: publicKey, payload: payload)
        } else {
            return try nip44Decrypt(privateKey: privateKey, publicKey: publicKey, payload: payload)
        }
    }

    static func encrypt(privateKey: Data, publicKey: Data, plaintext: String) throws -> String {
        // Always encrypt with NIP-44 (modern standard)
        return try nip44Encrypt(privateKey: privateKey, publicKey: publicKey, plaintext: plaintext)
    }

    // MARK: - NIP-04 (legacy, AES-256-CBC)

    static func nip04Decrypt(privateKey: Data, publicKey: Data, payload: String) throws -> String {
        let parts = payload.components(separatedBy: "?iv=")
        guard parts.count == 2,
              let ciphertext = Data(base64Encoded: parts[0]),
              let iv = Data(base64Encoded: parts[1]) else {
            throw LightCryptoError.invalidBase64
        }

        // NIP-04 ECDH: SHA-256 hash of the shared point x-coordinate
        let sharedKey = try getNip04SharedKey(privateKey: privateKey, publicKey: publicKey)

        // AES-256-CBC decrypt
        let decrypted = try aesCBCDecrypt(data: ciphertext, key: sharedKey, iv: iv)
        guard let plaintext = String(data: decrypted, encoding: .utf8) else {
            throw LightCryptoError.invalidUTF8
        }
        return plaintext
    }

    static func nip04Encrypt(privateKey: Data, publicKey: Data, plaintext: String) throws -> String {
        let sharedKey = try getNip04SharedKey(privateKey: privateKey, publicKey: publicKey)
        let plaintextData = Data(plaintext.utf8)

        // Generate random IV
        var ivBytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, 16, &ivBytes) == errSecSuccess else {
            throw LightCryptoError.randomGenerationFailed
        }
        let iv = Data(ivBytes)

        let encrypted = try aesCBCEncrypt(data: plaintextData, key: sharedKey, iv: iv)
        return "\(encrypted.base64EncodedString())?iv=\(iv.base64EncodedString())"
    }

    private static func getNip04SharedKey(privateKey: Data, publicKey: Data) throws -> Data {
        let compressedPubkey: Data
        if publicKey.count == 32 {
            compressedPubkey = Data([0x02]) + publicKey
        } else if publicKey.count == 33 {
            compressedPubkey = publicKey
        } else {
            throw LightCryptoError.invalidPublicKey
        }

        let privKey = try P256K.KeyAgreement.PrivateKey(dataRepresentation: privateKey, format: .compressed)
        let pubKey = try P256K.KeyAgreement.PublicKey(dataRepresentation: compressedPubkey, format: .compressed)

        let sharedPoint = privKey.sharedSecretFromKeyAgreement(with: pubKey)
        let sharedData = sharedPoint.withUnsafeBytes { Data($0) }
        let sharedX: Data
        if sharedData.count == 33 {
            sharedX = Data(sharedData.dropFirst())
        } else {
            sharedX = sharedData
        }

        // NIP-04 uses the raw x-coordinate as the AES-256 key (no hash)
        return sharedX
    }

    private static func aesCBCDecrypt(data: Data, key: Data, iv: Data) throws -> Data {
        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var numBytesDecrypted: size_t = 0

        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { dataBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count,
                        ivBytes.baseAddress,
                        dataBytes.baseAddress, data.count,
                        &buffer, bufferSize,
                        &numBytesDecrypted
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw LightCryptoError.invalidMAC // reuse error for decrypt failure
        }
        return Data(buffer.prefix(numBytesDecrypted))
    }

    private static func aesCBCEncrypt(data: Data, key: Data, iv: Data) throws -> Data {
        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var numBytesEncrypted: size_t = 0

        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { dataBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count,
                        ivBytes.baseAddress,
                        dataBytes.baseAddress, data.count,
                        &buffer, bufferSize,
                        &numBytesEncrypted
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw LightCryptoError.randomGenerationFailed // reuse error
        }
        return Data(buffer.prefix(numBytesEncrypted))
    }

    // MARK: - NIP-44 Public API

    static func nip44Decrypt(privateKey: Data, publicKey: Data, payload: String) throws -> String {
        let conversationKey = try getConversationKey(privateKey: privateKey, publicKey: publicKey)
        return try decrypt(payload: payload, conversationKey: conversationKey)
    }

    static func nip44Encrypt(privateKey: Data, publicKey: Data, plaintext: String) throws -> String {
        let conversationKey = try getConversationKey(privateKey: privateKey, publicKey: publicKey)
        var nonceBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &nonceBytes) == errSecSuccess else {
            throw LightCryptoError.randomGenerationFailed
        }
        let nonce = Data(nonceBytes)
        return try encrypt(plaintext: plaintext, conversationKey: conversationKey, nonce: nonce)
    }

    // MARK: - Conversation Key (ECDH + HKDF)

    static func getConversationKey(privateKey: Data, publicKey: Data) throws -> Data {
        let compressedPubkey: Data
        if publicKey.count == 32 {
            compressedPubkey = Data([0x02]) + publicKey
        } else if publicKey.count == 33 {
            compressedPubkey = publicKey
        } else {
            throw LightCryptoError.invalidPublicKey
        }

        let privKey = try P256K.KeyAgreement.PrivateKey(
            dataRepresentation: privateKey,
            format: .compressed
        )

        let pubKey = try P256K.KeyAgreement.PublicKey(
            dataRepresentation: compressedPubkey,
            format: .compressed
        )

        // ECDH returns compressed point (33 bytes: prefix + 32-byte x)
        // NIP-44 needs unhashed x-coordinate only (drop the prefix byte)
        let sharedPoint = privKey.sharedSecretFromKeyAgreement(with: pubKey)
        let sharedData = sharedPoint.withUnsafeBytes { Data($0) }
        let sharedX: Data
        if sharedData.count == 33 {
            sharedX = Data(sharedData.dropFirst())
        } else if sharedData.count == 32 {
            sharedX = sharedData
        } else {
            throw LightCryptoError.invalidPublicKey
        }

        let salt = Data("nip44-v2".utf8)
        let conversationKey = hkdfExtract(salt: salt, ikm: sharedX)
        return conversationKey
    }

    // MARK: - Encrypt

    static func encrypt(plaintext: String, conversationKey: Data, nonce: Data) throws -> String {
        guard conversationKey.count == 32 else { throw LightCryptoError.invalidConversationKey }
        guard nonce.count == 32 else { throw LightCryptoError.invalidNonce }

        let (chachaKey, chachaNonce, hmacKey) = getMessageKeys(conversationKey: conversationKey, nonce: nonce)
        let padded = try pad(plaintext: plaintext)
        let ciphertext = chacha20(key: chachaKey, nonce: chachaNonce, data: padded)
        let mac = hmacAAD(key: hmacKey, message: ciphertext, aad: nonce)

        var result = Data()
        result.append(0x02)
        result.append(nonce)
        result.append(ciphertext)
        result.append(mac)

        return result.base64EncodedString()
    }

    // MARK: - Decrypt

    static func decrypt(payload: String, conversationKey: Data) throws -> String {
        guard !payload.isEmpty else { throw LightCryptoError.emptyPayload }
        guard payload.first != "#" else { throw LightCryptoError.unsupportedVersion }

        // Handle base64 with or without padding
        var b64 = payload
        let remainder = b64.count % 4
        if remainder != 0 {
            b64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: b64) else {
            throw LightCryptoError.invalidBase64
        }

        guard data.count >= 99 && data.count <= 65603 else {
            throw LightCryptoError.invalidPayloadSize
        }

        let version = data[0]
        guard version == 0x02 else {
            throw LightCryptoError.unsupportedVersion
        }

        let nonce = data[1..<33]
        let ciphertext = data[33..<(data.count - 32)]
        let mac = data[(data.count - 32)...]

        let (chachaKey, chachaNonce, hmacKey) = getMessageKeys(conversationKey: conversationKey, nonce: Data(nonce))

        let calculatedMAC = hmacAAD(key: hmacKey, message: Data(ciphertext), aad: Data(nonce))
        let macData = Data(mac)
        guard constantTimeEqual(calculatedMAC, macData) else {
            throw LightCryptoError.invalidMAC
        }

        let padded = chacha20(key: chachaKey, nonce: chachaNonce, data: Data(ciphertext))
        return try unpad(padded: padded)
    }

    // MARK: - Message Keys (HKDF-expand)

    static func getMessageKeys(conversationKey: Data, nonce: Data) -> (chachaKey: Data, chachaNonce: Data, hmacKey: Data) {
        let keys = hkdfExpand(prk: conversationKey, info: nonce, length: 76)
        let chachaKey = keys[0..<32]
        let chachaNonce = keys[32..<44]
        let hmacKey = keys[44..<76]
        return (Data(chachaKey), Data(chachaNonce), Data(hmacKey))
    }

    // MARK: - HKDF (RFC 5869)

    private static func hkdfExtract(salt: Data, ikm: Data) -> Data {
        let key = SymmetricKey(data: salt)
        let code = HMAC<CryptoKit.SHA256>.authenticationCode(for: ikm, using: key)
        return Data(code)
    }

    private static func hkdfExpand(prk: Data, info: Data, length: Int) -> Data {
        var output = Data()
        var t = Data()
        var counter: UInt8 = 1

        while output.count < length {
            var input = t
            input.append(info)
            input.append(counter)
            let key = SymmetricKey(data: prk)
            let code = HMAC<CryptoKit.SHA256>.authenticationCode(for: input, using: key)
            t = Data(code)
            output.append(t)
            counter += 1
        }

        return Data(output.prefix(length))
    }

    // MARK: - HMAC-SHA256 with AAD

    private static func hmacAAD(key: Data, message: Data, aad: Data) -> Data {
        var input = Data()
        input.append(aad)
        input.append(message)
        let symKey = SymmetricKey(data: key)
        let code = HMAC<CryptoKit.SHA256>.authenticationCode(for: input, using: symKey)
        return Data(code)
    }

    // MARK: - Constant-time comparison

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for i in 0..<a.count {
            result |= a[a.startIndex + i] ^ b[b.startIndex + i]
        }
        return result == 0
    }

    // MARK: - Padding (NIP-44)

    private static func calcPaddedLen(_ unpaddedLen: Int) -> Int {
        if unpaddedLen <= 32 { return 32 }
        let nextPower = 1 << (Int(log2(Double(unpaddedLen - 1))) + 1)
        let chunk: Int
        if nextPower <= 256 {
            chunk = 32
        } else {
            chunk = nextPower / 8
        }
        return chunk * (((unpaddedLen - 1) / chunk) + 1)
    }

    private static func pad(plaintext: String) throws -> Data {
        let unpadded = Data(plaintext.utf8)
        let unpaddedLen = unpadded.count
        guard unpaddedLen >= 1 && unpaddedLen <= 65535 else {
            throw LightCryptoError.invalidPlaintextLength
        }
        let paddedLen = calcPaddedLen(unpaddedLen)
        var result = Data()
        result.append(UInt8((unpaddedLen >> 8) & 0xFF))
        result.append(UInt8(unpaddedLen & 0xFF))
        result.append(unpadded)
        result.append(Data(count: paddedLen - unpaddedLen))
        return result
    }

    private static func unpad(padded: Data) throws -> String {
        guard padded.count >= 2 else { throw LightCryptoError.invalidPadding }
        let unpaddedLen = Int(padded[padded.startIndex]) << 8 | Int(padded[padded.startIndex + 1])
        guard unpaddedLen > 0 else { throw LightCryptoError.invalidPadding }
        let unpaddedStart = padded.startIndex + 2
        let unpaddedEnd = unpaddedStart + unpaddedLen
        guard unpaddedEnd <= padded.endIndex else { throw LightCryptoError.invalidPadding }
        guard padded.count == 2 + calcPaddedLen(unpaddedLen) else { throw LightCryptoError.invalidPadding }
        let unpadded = padded[unpaddedStart..<unpaddedEnd]
        guard let str = String(data: Data(unpadded), encoding: .utf8) else {
            throw LightCryptoError.invalidUTF8
        }
        return str
    }

    // MARK: - ChaCha20 (RFC 8439, counter=0)

    static func chacha20(key: Data, nonce: Data, data: Data) -> Data {
        var state = [UInt32](repeating: 0, count: 16)
        state[0] = 0x61707865
        state[1] = 0x3320646e
        state[2] = 0x79622d32
        state[3] = 0x6b206574

        for i in 0..<8 {
            let offset = i * 4
            state[4 + i] = UInt32(key[key.startIndex + offset])
                | (UInt32(key[key.startIndex + offset + 1]) << 8)
                | (UInt32(key[key.startIndex + offset + 2]) << 16)
                | (UInt32(key[key.startIndex + offset + 3]) << 24)
        }

        state[12] = 0

        for i in 0..<3 {
            let offset = i * 4
            state[13 + i] = UInt32(nonce[nonce.startIndex + offset])
                | (UInt32(nonce[nonce.startIndex + offset + 1]) << 8)
                | (UInt32(nonce[nonce.startIndex + offset + 2]) << 16)
                | (UInt32(nonce[nonce.startIndex + offset + 3]) << 24)
        }

        var output = Data(count: data.count)
        var offset = 0

        while offset < data.count {
            var working = state
            for _ in 0..<10 {
                quarterRound(&working, 0, 4, 8, 12)
                quarterRound(&working, 1, 5, 9, 13)
                quarterRound(&working, 2, 6, 10, 14)
                quarterRound(&working, 3, 7, 11, 15)
                quarterRound(&working, 0, 5, 10, 15)
                quarterRound(&working, 1, 6, 11, 12)
                quarterRound(&working, 2, 7, 8, 13)
                quarterRound(&working, 3, 4, 9, 14)
            }

            for i in 0..<16 {
                working[i] = working[i] &+ state[i]
            }

            let blockSize = min(64, data.count - offset)
            for i in 0..<blockSize {
                let wordIndex = i / 4
                let byteIndex = i % 4
                let keystreamByte = UInt8((working[wordIndex] >> (byteIndex * 8)) & 0xFF)
                output[offset + i] = data[data.startIndex + offset + i] ^ keystreamByte
            }

            offset += 64
            state[12] = state[12] &+ 1
        }

        return output
    }

    private static func quarterRound(_ state: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        state[a] = state[a] &+ state[b]; state[d] ^= state[a]; state[d] = (state[d] << 16) | (state[d] >> 16)
        state[c] = state[c] &+ state[d]; state[b] ^= state[c]; state[b] = (state[b] << 12) | (state[b] >> 20)
        state[a] = state[a] &+ state[b]; state[d] ^= state[a]; state[d] = (state[d] << 8) | (state[d] >> 24)
        state[c] = state[c] &+ state[d]; state[b] ^= state[c]; state[b] = (state[b] << 7) | (state[b] >> 25)
    }
}

enum LightCryptoError: LocalizedError {
    case invalidPublicKey
    case invalidConversationKey
    case invalidNonce
    case emptyPayload
    case unsupportedVersion
    case invalidBase64
    case invalidPayloadSize
    case invalidMAC
    case invalidPadding
    case invalidPlaintextLength
    case invalidUTF8
    case randomGenerationFailed

    var errorDescription: String? {
        switch self {
        case .invalidPublicKey: return "Invalid public key"
        case .invalidConversationKey: return "Invalid conversation key"
        case .invalidNonce: return "Invalid nonce"
        case .emptyPayload: return "Empty payload"
        case .unsupportedVersion: return "Unsupported NIP-44 version"
        case .invalidBase64: return "Invalid base64"
        case .invalidPayloadSize: return "Invalid payload size"
        case .invalidMAC: return "Invalid MAC"
        case .invalidPadding: return "Invalid padding"
        case .invalidPlaintextLength: return "Plaintext must be 1-65535 bytes"
        case .invalidUTF8: return "Invalid UTF-8"
        case .randomGenerationFailed: return "Failed to generate random bytes"
        }
    }
}
