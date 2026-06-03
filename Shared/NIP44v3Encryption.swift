// NIP-44 v3 ChaCha20 + HMAC-SHA256 encryption layer.
//
// Spec: https://github.com/nostr-land/nip44v3/blob/main/nip44v3.md
// Pinned to commit 5680754 (2026-06-02).
// Reference impl: https://github.com/nostr-land/ncrypt-go (BSD-3).
//
// Layer: Encryption — composes pre-derived (encryption_key, mac_key, nonce)
// with kind + scope into the ChaCha20-encrypted body and HMAC-SHA256 tag.
// Stays one level below the wire framing (Ciphertext layer, future).
//
// Validated against:
//   - 10 `encrypt_decrypt` vectors (round-trip in both directions)
//   - 5  `decrypt_only` vectors (non-standard padding, the Amber gotcha)
//   - 18 `long_encrypt_decrypt` vectors (SHA-256 of full wire)
//   - 8  `invalid_decryption` vectors at the encryption layer
//     (MAC tampering, padding tampering, kind mismatch, scope mismatch)

import Foundation
import CryptoKit

extension NIP44v3 {

    /// Encryption namespace for NIP-44 v3.
    ///
    /// Given pre-derived `encryptionKey` + `macKey` (from `NIP44v3.Keys`) plus
    /// a per-message `nonce`, `kind`, and binary `scope`, encrypts a padded,
    /// length-prefixed plaintext with ChaCha20 (all-zero 12-byte IV, counter
    /// from 0) and authenticates with HMAC-SHA256 over a context-bound prefix.
    enum Encryption {

        /// Errors specific to the Encryption layer.
        ///
        /// The eventual Errors layer (ncrypt-go's `nip44v3/errors.go`) may
        /// consolidate these with the Keys + Ciphertext layers' errors. For
        /// now they live local to the file to keep the per-layer port additive.
        enum Error: Swift.Error, Equatable {
            case invalidEncryptionKeyLength
            case invalidMacKeyLength
            case invalidNonceLength
            case plaintextTooLong
            case ciphertextTooShort
            case macInvalid
            case paddingInvalid
            case plaintextOutOfBounds
        }

        /// Encrypts `plaintext` per spec steps 3-7 of the Encryption Algorithm.
        ///
        ///   prefixed_plaintext = u32_be(len(plaintext)) || plaintext
        ///   padded_plaintext   = prefixed_plaintext || zeros(target_size - len)
        ///   chacha20_ct        = ChaCha20(encryptionKey, padded_plaintext)
        ///   ad                 = nonce || u32_be(kind) || u32_be(len(scope))
        ///                        || scope || chacha20_ct
        ///   mac                = HMAC-SHA256(macKey, ad)
        ///
        /// Returns the ChaCha20 ciphertext body (NOT the full wire — that
        /// framing is the Ciphertext layer's job) and the 32-byte HMAC-SHA256
        /// authentication tag.
        ///
        /// - Parameters:
        ///   - plaintext: Raw bytes to encrypt (may be empty; max 2^31 - 1).
        ///   - encryptionKey: 32-byte ChaCha20 key, from `NIP44v3.Keys.derive`.
        ///   - macKey: 32-byte HMAC key, from `NIP44v3.Keys.derive`.
        ///   - kind: Event kind. Bound into the MAC's authenticated prefix.
        ///   - scope: Caller-supplied scope bytes (raw, not UTF-8-validated
        ///     here — UTF-8 validation belongs at the public API layer).
        ///   - nonce: 32-byte per-message nonce (also used as part of the MAC
        ///     authenticated prefix and as the HKDF salt for key derivation).
        /// - Returns: `(chacha20Ciphertext, mac)`.
        /// - Throws: `Error.invalidEncryptionKeyLength` / `.invalidMacKeyLength`
        ///           / `.invalidNonceLength` for malformed key/nonce inputs;
        ///           `.plaintextTooLong` if `plaintext.count > 2^31 - 1`.
        static func encrypt(
            plaintext: Data,
            encryptionKey: Data,
            macKey: Data,
            kind: UInt32,
            scope: Data,
            nonce: Data
        ) throws -> (chacha20Ciphertext: Data, mac: Data) {
            guard encryptionKey.count == 32 else { throw Error.invalidEncryptionKeyLength }
            guard macKey.count == 32        else { throw Error.invalidMacKeyLength }
            guard nonce.count == 32         else { throw Error.invalidNonceLength }
            guard plaintext.count <= 0x7fff_ffff else { throw Error.plaintextTooLong }

            let prefixedLen = 4 + plaintext.count
            let targetSize  = Padding.targetSize(forLength: prefixedLen)

            var padded = Data(count: targetSize)
            padded.withUnsafeMutableBytes { rawBuf in
                let buf = rawBuf.bindMemory(to: UInt8.self)
                let n = UInt32(plaintext.count)
                buf[0] = UInt8((n >> 24) & 0xff)
                buf[1] = UInt8((n >> 16) & 0xff)
                buf[2] = UInt8((n >> 8)  & 0xff)
                buf[3] = UInt8(n         & 0xff)
                if !plaintext.isEmpty {
                    _ = plaintext.withUnsafeBytes { p in
                        memcpy(buf.baseAddress!.advanced(by: 4), p.baseAddress!, plaintext.count)
                    }
                }
                // remaining bytes [prefixedLen ..< targetSize] already zero
            }

            let chachaCt = chacha20(key: encryptionKey, plaintext: padded)
            let mac      = computeMac(macKey: macKey, nonce: nonce, kind: kind, scope: scope, chacha20Ct: chachaCt)
            return (chachaCt, mac)
        }

        /// Decrypts `chacha20Ciphertext` per spec steps 5-11 of the Decryption
        /// Algorithm. The caller supplies the `kind` and `scope` they expect
        /// the message to belong to — these are folded into the MAC verify,
        /// so a context mismatch is indistinguishable from MAC tampering.
        ///
        /// ⚠ The all-zeros padding check is constant-time but DOES NOT check
        /// that the padding length matches `Padding.targetSize(plaintextLen)`.
        /// Per spec commit `c6daedd`: "Implementations MUST NOT do any other
        /// checks on the padding length." Validating that would reject the
        /// 5 `decrypt_only` test vectors.
        ///
        /// - Parameters:
        ///   - chacha20Ciphertext: ChaCha20-encrypted body (NOT the full wire).
        ///   - mac: 32-byte HMAC-SHA256 tag from the wire.
        ///   - encryptionKey: 32-byte ChaCha20 key.
        ///   - macKey: 32-byte HMAC key.
        ///   - kind: Caller's expected event kind.
        ///   - scope: Caller's expected scope bytes.
        ///   - nonce: 32-byte per-message nonce from the wire.
        /// - Returns: The recovered plaintext bytes.
        /// - Throws: `Error.macInvalid` / `.paddingInvalid` /
        ///           `.ciphertextTooShort` / `.plaintextOutOfBounds` /
        ///           `.plaintextTooLong` on any decryption-layer failure.
        ///           Length-validation errors on inputs map to
        ///           `.invalidEncryptionKeyLength` etc.
        static func decrypt(
            chacha20Ciphertext: Data,
            mac: Data,
            encryptionKey: Data,
            macKey: Data,
            kind: UInt32,
            scope: Data,
            nonce: Data
        ) throws -> Data {
            guard encryptionKey.count == 32 else { throw Error.invalidEncryptionKeyLength }
            guard macKey.count == 32        else { throw Error.invalidMacKeyLength }
            guard nonce.count == 32         else { throw Error.invalidNonceLength }

            // Verify MAC FIRST, constant-time. Spec binds (kind, scope) into
            // the MAC, so caller-supplied context mismatch surfaces here.
            let expectedMac = computeMac(macKey: macKey, nonce: nonce, kind: kind, scope: scope, chacha20Ct: chacha20Ciphertext)
            guard constantTimeEqual(expectedMac, mac) else { throw Error.macInvalid }

            // ChaCha20 needs at least 4 bytes to recover the length prefix.
            guard chacha20Ciphertext.count >= 4 else { throw Error.ciphertextTooShort }

            // ChaCha20 is symmetric — decrypt by encrypting again.
            let padded = chacha20(key: encryptionKey, plaintext: chacha20Ciphertext)

            // Parse big-endian u32 length prefix.
            let plaintextLen64: UInt64 = padded.withUnsafeBytes { rawBuf in
                let p = rawBuf.bindMemory(to: UInt8.self).baseAddress!
                return (UInt64(p[0]) << 24) | (UInt64(p[1]) << 16) | (UInt64(p[2]) << 8) | UInt64(p[3])
            }
            guard plaintextLen64 <= 0x7fff_ffff else { throw Error.plaintextTooLong }
            let plaintextLen = Int(plaintextLen64)
            guard 4 + plaintextLen <= padded.count else { throw Error.plaintextOutOfBounds }

            // Constant-time all-zeros check on the padding tail.
            // CRITICAL: spec commit c6daedd forbids checking that the padding
            // length matches target_size(plaintextLen). Only the all-zeros
            // property is required — non-standard padding lengths are spec-
            // compliant and MUST decrypt successfully.
            guard constantTimeAllZero(padded, from: 4 + plaintextLen, to: padded.count) else {
                throw Error.paddingInvalid
            }

            return padded.subdata(in: padded.startIndex.advanced(by: 4) ..< padded.startIndex.advanced(by: 4 + plaintextLen))
        }

        // MARK: - Internal primitives (private to this layer)

        /// `mac = HMAC-SHA256(macKey, nonce || u32_be(kind) || u32_be(len(scope))
        ///                    || scope || chacha20_ct)`.
        private static func computeMac(
            macKey: Data,
            nonce: Data,
            kind: UInt32,
            scope: Data,
            chacha20Ct: Data
        ) -> Data {
            var hasher = HMAC<CryptoKit.SHA256>(key: SymmetricKey(data: macKey))
            hasher.update(data: nonce)
            withUnsafeBytes(of: kind.bigEndian) { hasher.update(data: Data($0)) }
            withUnsafeBytes(of: UInt32(scope.count).bigEndian) { hasher.update(data: Data($0)) }
            hasher.update(data: scope)
            hasher.update(data: chacha20Ct)
            return Data(hasher.finalize())
        }

        /// RFC 8439 ChaCha20 (20 rounds, 12-byte all-zero nonce, counter
        /// from 0). XORs the keystream against `plaintext` and returns the
        /// result. ChaCha20 is symmetric, so the same function decrypts.
        ///
        /// Mirrors the algorithm in `Shared/LightCrypto.swift` (NIP-44 v2
        /// path) — re-implemented locally per the per-layer additive port
        /// pattern, and because CryptoKit only exposes ChaChaPoly (AEAD),
        /// not raw ChaCha20.
        private static func chacha20(key: Data, plaintext: Data) -> Data {
            precondition(key.count == 32, "ChaCha20 key must be 32 bytes")
            let nonce = Data(count: 12)

            var state = [UInt32](repeating: 0, count: 16)
            state[0] = 0x6170_7865
            state[1] = 0x3320_646e
            state[2] = 0x7962_2d32
            state[3] = 0x6b20_6574
            for i in 0..<8 {
                let o = key.startIndex + i * 4
                state[4 + i] = UInt32(key[o])
                    | (UInt32(key[o + 1]) << 8)
                    | (UInt32(key[o + 2]) << 16)
                    | (UInt32(key[o + 3]) << 24)
            }
            state[12] = 0
            for i in 0..<3 {
                let o = nonce.startIndex + i * 4
                state[13 + i] = UInt32(nonce[o])
                    | (UInt32(nonce[o + 1]) << 8)
                    | (UInt32(nonce[o + 2]) << 16)
                    | (UInt32(nonce[o + 3]) << 24)
            }

            var output = Data(count: plaintext.count)
            output.withUnsafeMutableBytes { outRaw in
                let outBuf = outRaw.bindMemory(to: UInt8.self)
                plaintext.withUnsafeBytes { inRaw in
                    let inBuf = inRaw.bindMemory(to: UInt8.self)
                    var offset = 0
                    while offset < plaintext.count {
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
                        let blockSize = min(64, plaintext.count - offset)
                        for i in 0..<blockSize {
                            let w = working[i / 4]
                            let ks = UInt8((w >> ((i % 4) * 8)) & 0xff)
                            outBuf[offset + i] = inBuf[offset + i] ^ ks
                        }
                        offset += 64
                        state[12] = state[12] &+ 1
                    }
                }
            }
            return output
        }

        /// One ChaCha20 quarter-round on 32-bit lanes a, b, c, d.
        private static func quarterRound(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = (s[d] << 16) | (s[d] >> 16)
            s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = (s[b] << 12) | (s[b] >> 20)
            s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = (s[d] << 8)  | (s[d] >> 24)
            s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = (s[b] << 7)  | (s[b] >> 25)
        }

        /// Constant-time byte equality. Required for MAC comparison — `==`
        /// on `Data` early-exits on the first mismatching byte, leaking
        /// where the divergence is. XOR-fold + OR accumulator stays branch-
        /// free over the full length.
        private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
            guard a.count == b.count else { return false }
            var accum: UInt8 = 0
            let count = a.count
            a.withUnsafeBytes { aRaw in
                b.withUnsafeBytes { bRaw in
                    let ap = aRaw.bindMemory(to: UInt8.self).baseAddress!
                    let bp = bRaw.bindMemory(to: UInt8.self).baseAddress!
                    for i in 0..<count {
                        accum |= ap[i] ^ bp[i]
                    }
                }
            }
            return accum == 0
        }

        /// Constant-time "is this slice all zero?" check. Same OR-fold
        /// rationale as `constantTimeEqual` — early-exit on the first non-
        /// zero byte would leak the padding-length boundary.
        private static func constantTimeAllZero(_ d: Data, from: Int, to: Int) -> Bool {
            guard from <= to, to <= d.count else { return false }
            var accum: UInt8 = 0
            d.withUnsafeBytes { rawBuf in
                let p = rawBuf.bindMemory(to: UInt8.self).baseAddress!
                for i in from..<to {
                    accum |= p[i]
                }
            }
            return accum == 0
        }
    }
}
