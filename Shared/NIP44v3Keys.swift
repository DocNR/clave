// NIP-44 v3 per-message key derivation.
//
// Spec: https://github.com/nostr-land/nip44v3/blob/main/nip44v3.md
// Pinned to commit 5680754 (2026-06-02).
// Reference impl: https://github.com/nostr-land/ncrypt-go (BSD-3).
//
// Layer: Keys — given (seckey_a, pubkey_b, nonce), derives
//   `prk = HKDF-Extract(salt = "nip44-v3\x00" || nonce, ikm = ECDH(a, b))`
//   `encryption_key = HKDF-Expand(prk, info = "encryption_key", L = 32)`
//   `mac_key        = HKDF-Expand(prk, info = "mac_key",        L = 32)`
// Validated against all 10 `encrypt_decrypt` test vectors (both perspectives,
// 20 derivations total) from the spec test-vectors.json.

import Foundation
import CryptoKit
import P256K

extension NIP44v3 {

    /// Key-derivation namespace for NIP-44 v3.
    ///
    /// The two derived 32-byte keys (`encryptionKey`, `macKey`) feed the
    /// Encryption layer (ChaCha20 + HMAC-SHA256). The intermediate `prk` is
    /// exposed only for test-vector validation; production callers should
    /// ignore it.
    enum Keys {

        /// HKDF salt prefix per spec: literal ASCII `"nip44-v3"` followed by a
        /// single 0x00 byte (9 bytes total). Concatenated with the 32-byte
        /// per-message nonce to form the 41-byte salt fed into HKDF-Extract.
        static let saltPrefix: Data = {
            var d = Data("nip44-v3".utf8)
            d.append(0x00)
            return d
        }()

        /// HKDF-Expand `info` parameter that selects the 32-byte encryption key.
        static let encryptionKeyInfo: Data = Data("encryption_key".utf8)

        /// HKDF-Expand `info` parameter that selects the 32-byte MAC key.
        static let macKeyInfo: Data = Data("mac_key".utf8)

        /// Result of one derivation: the intermediate `prk` and the two
        /// 32-byte output keys.
        struct Derived: Equatable {
            let prk: Data
            let encryptionKey: Data
            let macKey: Data
        }

        /// Errors specific to the Keys layer.
        ///
        /// The eventual Errors layer (ncrypt-go's `nip44v3/errors.go`) may
        /// consolidate these. For now they live local to the file to keep the
        /// per-layer port additive.
        enum Error: Swift.Error, Equatable {
            case invalidSecretKeyLength
            case invalidPublicKeyLength
            case invalidNonceLength
            case invalidSecretKey
            case ecdhFailed
        }

        /// Derives `(prk, encryption_key, mac_key)` for one message.
        ///
        /// Spec algorithm:
        /// ```
        /// shared_secret = ECDH(seckey, pubkey)              // 32 bytes (x-coordinate)
        /// salt          = "nip44-v3\x00" || nonce            // 9 + 32 = 41 bytes
        /// prk           = HKDF-Extract(salt, shared_secret)  // 32 bytes
        /// enc_key       = HKDF-Expand(prk, "encryption_key", L=32)
        /// mac_key       = HKDF-Expand(prk, "mac_key",        L=32)
        /// ```
        ///
        /// - Parameters:
        ///   - seckey: Local 32-byte secp256k1 secret key.
        ///   - pubkey: Remote 32-byte x-only (BIP-340) public key.
        ///   - nonce: 32-byte per-message nonce.
        /// - Returns: Derived PRK + per-message encryption and MAC keys.
        /// - Throws: `Error.invalidSecretKeyLength` / `.invalidPublicKeyLength`
        ///           / `.invalidNonceLength` for malformed inputs;
        ///           `.invalidSecretKey` if `seckey` is zero or `>= n`;
        ///           `.ecdhFailed` if the underlying ECDH fails.
        static func derive(seckey: Data, pubkey: Data, nonce: Data) throws -> Derived {
            guard seckey.count == 32 else { throw Error.invalidSecretKeyLength }
            guard pubkey.count == 32 else { throw Error.invalidPublicKeyLength }
            guard nonce.count == 32 else { throw Error.invalidNonceLength }

            let sharedSecret = try ecdhSharedSecret(seckey: seckey, pubkey: pubkey)

            // salt = "nip44-v3\x00" || nonce  (9 + 32 = 41 bytes)
            var salt = saltPrefix
            salt.append(nonce)

            // HKDF-Extract: prk = HMAC-SHA256(key = salt, data = sharedSecret)
            let prkCode = HKDF<CryptoKit.SHA256>.extract(
                inputKeyMaterial: SymmetricKey(data: sharedSecret),
                salt: salt
            )
            let prk = Data(prkCode)

            // HKDF-Expand twice. Different `info`, same prk.
            let encryptionKey = HKDF<CryptoKit.SHA256>.expand(
                pseudoRandomKey: prkCode,
                info: encryptionKeyInfo,
                outputByteCount: 32
            ).withUnsafeBytes { Data($0) }

            let macKey = HKDF<CryptoKit.SHA256>.expand(
                pseudoRandomKey: prkCode,
                info: macKeyInfo,
                outputByteCount: 32
            ).withUnsafeBytes { Data($0) }

            return Derived(prk: prk, encryptionKey: encryptionKey, macKey: macKey)
        }

        /// Computes the 32-byte x-coordinate of the secp256k1 ECDH shared point.
        ///
        /// Mirrors `nostr-land/ncrypt-go/internal/ecutil.SharedSecret` (BIP-340
        /// x-only convention): the 32-byte x-only pubkey is interpreted with an
        /// implicit `0x02` (even-y) prefix, multiplied by `seckey`, and the
        /// resulting affine point's x-coordinate is returned unhashed.
        private static func ecdhSharedSecret(seckey: Data, pubkey: Data) throws -> Data {
            // BIP-340 x-only → compressed form for P256K's PublicKey parser.
            var compressedPubkey = Data([0x02])
            compressedPubkey.append(pubkey)

            let privKey: P256K.KeyAgreement.PrivateKey
            do {
                privKey = try P256K.KeyAgreement.PrivateKey(
                    dataRepresentation: seckey,
                    format: .compressed
                )
            } catch {
                throw Error.invalidSecretKey
            }

            let pubKey: P256K.KeyAgreement.PublicKey
            do {
                pubKey = try P256K.KeyAgreement.PublicKey(
                    dataRepresentation: compressedPubkey,
                    format: .compressed
                )
            } catch {
                throw Error.ecdhFailed
            }

            let sharedPoint = privKey.sharedSecretFromKeyAgreement(with: pubKey)
            let sharedData = sharedPoint.withUnsafeBytes { Data($0) }
            // libsecp256k1 returns the compressed point (33 bytes: prefix + x).
            // Strip the prefix to get the raw x-coordinate, as required by spec.
            switch sharedData.count {
            case 33: return Data(sharedData.dropFirst())
            case 32: return sharedData
            default: throw Error.ecdhFailed
            }
        }
    }
}
