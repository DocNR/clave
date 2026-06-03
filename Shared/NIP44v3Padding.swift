// NIP-44 v3 padding algorithm.
//
// Spec: https://github.com/nostr-land/nip44v3/blob/main/nip44v3.md
// Pinned to commit 5680754 (2026-06-02).
// Reference impl: https://github.com/nostr-land/ncrypt-go (BSD-3).
//
// Validated against all 176 padding test vectors from spec test-vectors.json.

import Foundation

/// Root namespace for NIP-44 v3 primitives.
///
/// Sub-namespaces will be added as remaining layers are ported:
///   - `Padding` (this file): message-size obfuscation chunking
///   - `Keys` (future): HKDF-based encryption/MAC key derivation
///   - `Encryption` (future): ChaCha20 + HMAC-SHA256 wrap
///   - `Ciphertext` (future): wire-format framing (version + nonce + mac + ctx + ct)
///   - `Context` (future): kind + scope packaging
enum NIP44v3 {}

extension NIP44v3 {

    /// Padding algorithm per the NIP-44 v3 spec.
    ///
    /// The padding obscures the rough size of messages without leaking the exact length.
    /// All implementations SHOULD use this algorithm to prevent fingerprinting.
    enum Padding {

        // Algorithm constants from spec
        static let minimumSize: Int = 32
        static let chunkSubdivsSmall: Int = 4
        static let chunkSubdivsLarge: Int = 8
        static let chunkLargeThreshold: Int = 32768

        /// Computes the target padded size for a message of length `len` bytes.
        ///
        /// Spec algorithm:
        /// ```
        /// if len == 0: return minimumSize
        /// next_power = 2 ** ceil(log2(len))
        /// chunk_subdivs = (next_power >= 32768) ? 8 : 4
        /// chunk_size = max(minimumSize, next_power / chunk_subdivs)
        /// target_size = chunk_size * ceil(len / chunk_size)
        /// ```
        ///
        /// Uses integer bit manipulation for `next_power` to avoid Float64
        /// precision issues at large input lengths.
        ///
        /// - Parameter len: The unpadded message length in bytes. Must be non-negative.
        /// - Returns: The target padded size in bytes (always >= `minimumSize`).
        static func targetSize(forLength len: Int) -> Int {
            precondition(len >= 0, "NIP44v3.Padding: length must be non-negative")

            if len == 0 { return minimumSize }

            // next_power = 2 ** ceil(log2(len))
            // For len == 1: ceil(log2(1)) == 0, so next_power == 1.
            // For len >= 2: shift one bit by (Int.bitWidth - leadingZeroBitCount(len - 1))
            //   to get the smallest power of two that is >= len, integer-exact.
            let nextPower: Int
            if len == 1 {
                nextPower = 1
            } else {
                nextPower = 1 << (Int.bitWidth - (len - 1).leadingZeroBitCount)
            }

            let chunkSubdivs = nextPower >= chunkLargeThreshold ? chunkSubdivsLarge : chunkSubdivsSmall
            let chunkSize = max(minimumSize, nextPower / chunkSubdivs)
            // ceil(len / chunkSize) without floats
            return chunkSize * ((len + chunkSize - 1) / chunkSize)
        }
    }
}
