// NIP-44 v3 wire-format framing (Ciphertext layer).
//
// Spec: https://github.com/nostr-land/nip44v3/blob/main/nip44v3.md
// Pinned to commit 5680754 (2026-06-02).
// Reference impl: https://github.com/nostr-land/ncrypt-go (BSD-3).
//
// Layer: Ciphertext — wire-format encode/decode for the canonical NIP-44 v3
// payload:
//
//   base64(
//     0x03                  // version (1 byte)
//     || nonce              // 32 bytes
//     || mac                // 32 bytes
//     || u32_be(kind)       // 4 bytes
//     || u32_be(scope_len)  // 4 bytes
//     || scope              // scope_len bytes
//     || chacha20_ciphertext // ≥ 4 bytes
//   )
//
// Subsumes the inline `parseWire`/`assembleWire` helpers in
// `NIP44v3EncryptionTests.swift` (lines 376-425). The Encryption-test inline
// copies are intentionally preserved so each layer's tests remain self-
// contained for review symmetry; production callers should reach for the
// public API in this file.
//
// Validated against:
//   - 10 `encrypt_decrypt` vectors — encode + decode round-trip
//   - 10 `invalid_decryption` vectors (indices 4-13) — wire-frame rejection
//   - 7 synthetic edge cases at the spec boundaries
//
// Scope of this layer:
//   - Wire bytes ↔ structured `Parts`
//   - Version byte enforcement (0x03 only)
//   - Size + scope-length bounds checks
//   - Base64 encode/decode at the string boundary
//   - The `#` prefix sentinel reserved for future non-base64 encodings
// NOT this layer's job (deferred to the Context layer):
//   - UTF-8 validation of `scope` bytes (matches the split called out in
//     `NIP44v3EncryptionTests.swift` lines 123-127: index 18 of the spec
//     `invalid_decryption` set is owned by the future Context chip).

import Foundation

extension NIP44v3 {

    /// Wire-format framing namespace for NIP-44 v3.
    ///
    /// The full message-layer pipeline is `Keys → Encryption → Ciphertext →
    /// (top-level API)`. This layer handles only the bytes-and-base64
    /// framing on the outermost edge — context binding into the MAC,
    /// padding, key derivation, and UTF-8 validation all live in adjacent
    /// layers.
    enum Ciphertext {

        // MARK: - Public types

        /// Parsed components of a wire ciphertext, in the canonical order
        /// they appear on the wire after the 0x03 version byte.
        struct Parts: Equatable {
            /// 32-byte per-message nonce.
            let nonce: Data
            /// 32-byte HMAC-SHA256 tag.
            let mac: Data
            /// Event kind, encoded as `u32_be` on the wire.
            let kind: UInt32
            /// Caller-supplied scope bytes (raw — UTF-8 validation belongs
            /// to the Context layer, not this one).
            let scope: Data
            /// ChaCha20-encrypted padded plaintext. Must be ≥ 4 bytes to
            /// carry the length prefix the Encryption layer reads on
            /// decrypt.
            let chacha20Ciphertext: Data
        }

        /// Errors specific to the Ciphertext (wire-framing) layer.
        ///
        /// Distinct from `NIP44v3.Encryption.Error` and `NIP44v3.Keys.Error`
        /// because failures here are purely structural — the wire didn't
        /// parse, no cryptographic check ever ran. The eventual top-level
        /// API may consolidate these into a unified `NIP44v3.Error` set; for
        /// now the per-layer split mirrors ncrypt-go's package layout.
        enum Error: Swift.Error, Equatable {
            /// Input string had zero length. Distinguished from
            /// `.ciphertextTooShort` so callers can report "no payload" vs
            /// "payload was truncated" at higher layers.
            case empty
            /// Either the base64 input started with `#` (reserved for
            /// future non-base64 encodings) or the decoded first byte was
            /// not 0x03. Carries the offending byte for diagnostics.
            case unsupportedVersion(byte: UInt8)
            /// Decoded wire was shorter than the 77-byte minimum that holds
            /// the fixed-size header + 0-byte scope + 4-byte chacha20_ct.
            case ciphertextTooShort
            /// `scope_len + 73 > total decoded size` — the scope field
            /// claims more bytes than the wire actually carries.
            case scopeLengthOutOfBounds
            /// `chacha20_ct < 4` bytes. The Encryption layer reads a
            /// big-endian u32 length prefix from the first 4 plaintext
            /// bytes, so anything shorter is structurally undecryptable.
            case chacha20CiphertextTooShort
            /// `Data(base64Encoded:)` returned nil — the input was not
            /// valid standard base64.
            case base64DecodeFailed
        }

        // MARK: - Constants

        /// Wire version byte for NIP-44 v3. Reserved alternatives in the
        /// spec: v2 (0x02) and v4+ (future). Anything else is rejected at
        /// decode time.
        static let version: UInt8 = 0x03

        /// `1 (version) + 32 (nonce) + 32 (mac) + 4 (kind) + 4 (scope_len) +
        /// 0 (scope) + 4 (min chacha20_ct)` — the smallest valid wire.
        static let minimumWireSize: Int = 77

        /// The Encryption layer's first 4 plaintext bytes carry the
        /// big-endian length prefix, so the chacha20 ciphertext must be at
        /// least that long to be structurally decryptable.
        static let minimumChacha20CiphertextSize: Int = 4

        // MARK: - Encode

        /// Encodes `parts` into the canonical base64 wire form.
        ///
        /// Equivalent to `encodeBytes(parts).base64EncodedString()`; provided
        /// as the convenience entry point most callers want.
        static func encode(_ parts: Parts) -> String {
            encodeBytes(parts).base64EncodedString()
        }

        /// Encodes `parts` into the raw wire bytes (the pre-base64 buffer).
        ///
        /// Exposed for callers that need the raw bytes — e.g. to hash the
        /// ciphertext, attach it to a binary protocol, or feed it back into
        /// `decodeBytes`.
        static func encodeBytes(_ parts: Parts) -> Data {
            var buf = Data()
            buf.reserveCapacity(73 + parts.scope.count + parts.chacha20Ciphertext.count)
            buf.append(version)
            buf.append(parts.nonce)
            buf.append(parts.mac)
            appendU32BE(&buf, parts.kind)
            appendU32BE(&buf, UInt32(parts.scope.count))
            buf.append(parts.scope)
            buf.append(parts.chacha20Ciphertext)
            return buf
        }

        // MARK: - Decode

        /// Decodes a base64 wire string into structured `Parts`.
        ///
        /// Per spec (commit `5680754`) decryption-algorithm steps 1-3 plus
        /// the chacha20_ct length check from step 3 trailing line:
        ///
        ///   1. `length(ciphertext) == 0` → fail (`.empty`)
        ///   2. `ciphertext[0] == '#'`    → fail (`.unsupportedVersion`).
        ///      The `#` byte is reserved for future non-base64 encodings —
        ///      checked on the INPUT STRING, before base64 decode (matches
        ///      ncrypt-go's `ciphertext.go` line 54).
        ///   3. base64 decode                → fail with `.base64DecodeFailed`
        ///      on bad input.
        ///   4. `length(decoded) < 77`       → fail (`.ciphertextTooShort`)
        ///   5. `decoded[0] != 3`            → fail (`.unsupportedVersion`)
        ///   6. parse `nonce`, `mac`, `kind`, `scope_len`
        ///   7. `scope_len + 73 > length(decoded)` → fail
        ///      (`.scopeLengthOutOfBounds`)
        ///   8. `length(chacha20_ct) < 4`     → fail
        ///      (`.chacha20CiphertextTooShort`)
        ///
        /// - Parameter base64: Standard base64-encoded wire ciphertext.
        /// - Throws: `Error` cases above.
        /// - Returns: Parsed components.
        static func decode(_ base64: String) throws -> Parts {
            // Step 1: empty input.
            if base64.isEmpty { throw Error.empty }

            // Step 2: '#' prefix sentinel (reserved for future non-base64
            // encodings). Checked on the INPUT STRING, not the decoded
            // bytes — '#' is not in the standard base64 alphabet, so by the
            // time the user could see `decoded[0] == '#'` the input would
            // already have failed step 3.
            if base64.first == "#" {
                throw Error.unsupportedVersion(byte: 0x23)
            }

            // Step 3: base64 decode.
            guard let raw = Data(base64Encoded: base64) else {
                throw Error.base64DecodeFailed
            }

            // Steps 4-8 live in decodeBytes so callers with raw wire don't
            // have to re-base64-encode just to use the same checks.
            return try decodeBytes(raw)
        }

        /// Decodes raw wire bytes (already base64-decoded) into structured
        /// `Parts`. Runs spec steps 4-8 from the Decryption Algorithm.
        ///
        /// - Parameter data: Raw wire bytes.
        /// - Throws: `Error.ciphertextTooShort`, `.unsupportedVersion`,
        ///           `.scopeLengthOutOfBounds`, or
        ///           `.chacha20CiphertextTooShort` on a structurally invalid
        ///           wire. Never throws `.empty` or `.base64DecodeFailed` —
        ///           those are string-API concerns.
        static func decodeBytes(_ data: Data) throws -> Parts {
            // Step 4: minimum decoded size.
            guard data.count >= minimumWireSize else {
                throw Error.ciphertextTooShort
            }

            // `Data` index arithmetic must be relative to `startIndex` to
            // stay correct when callers pass a slice rather than a freshly
            // constructed `Data` (the existing Encryption-test inline
            // parser does this — see lines 382-395).
            let base = data.startIndex

            // Step 5: version byte.
            let versionByte = data[base]
            guard versionByte == version else {
                throw Error.unsupportedVersion(byte: versionByte)
            }

            // Step 6 prep: read scope_len at offset 69 (before bounds-
            // checking it — we need the value to compute remaining bytes).
            let kind = readU32BE(data, offset: base + 65)
            let scopeLen = Int(readU32BE(data, offset: base + 69))

            // Step 7: scope_len + 73 must not run past the end of the wire.
            // Phrased this way to match ncrypt-go's check exactly
            // (`ciphertext.go` line 73). Equivalent to checking that
            // `scopeEnd <= data.count` below.
            guard scopeLen + 73 <= data.count else {
                throw Error.scopeLengthOutOfBounds
            }

            // Step 8: chacha20_ct must carry at least the 4-byte length
            // prefix the Encryption layer reads on decrypt.
            let chacha20Len = data.count - 73 - scopeLen
            guard chacha20Len >= minimumChacha20CiphertextSize else {
                throw Error.chacha20CiphertextTooShort
            }

            // Parse fields (all bounds already validated above).
            let nonce = Data(data[(base + 1)..<(base + 33)])
            let mac = Data(data[(base + 33)..<(base + 65)])
            let scopeStart = base + 73
            let scopeEnd = scopeStart + scopeLen
            let scope = Data(data[scopeStart..<scopeEnd])
            let chacha20Ciphertext = Data(data[scopeEnd..<data.endIndex])

            return Parts(
                nonce: nonce,
                mac: mac,
                kind: kind,
                scope: scope,
                chacha20Ciphertext: chacha20Ciphertext
            )
        }

        // MARK: - Internal byte helpers

        /// Big-endian unsigned 32-bit read at a `Data.Index`. Manual
        /// shift-and-or rather than `withUnsafeBytes` / `load(as:)` to keep
        /// the layer dependency-free and to avoid alignment surprises on
        /// odd byte boundaries.
        private static func readU32BE(_ d: Data, offset: Data.Index) -> UInt32 {
            var v: UInt32 = 0
            v |= UInt32(d[offset]) << 24
            v |= UInt32(d[offset + 1]) << 16
            v |= UInt32(d[offset + 2]) << 8
            v |= UInt32(d[offset + 3])
            return v
        }

        /// Big-endian unsigned 32-bit append.
        private static func appendU32BE(_ d: inout Data, _ v: UInt32) {
            d.append(UInt8((v >> 24) & 0xff))
            d.append(UInt8((v >> 16) & 0xff))
            d.append(UInt8((v >> 8) & 0xff))
            d.append(UInt8(v & 0xff))
        }
    }
}
