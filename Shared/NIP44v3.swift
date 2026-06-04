// NIP-44 v3 top-level public API.
//
// Spec: https://github.com/nostr-land/nip44v3/blob/main/nip44v3.md
// Pinned to commit 5680754 (2026-06-02).
// Reference impl: https://github.com/nostr-land/ncrypt-go (BSD-3).
//
// Layer: top-level — composes Keys + Encryption + Ciphertext + Context into
// the `(seckey, pubkey, context, plaintext) -> base64-wire` and inverse
// entry points the eventual NIP-46 dispatch in `LightSigner.swift` will
// call.
//
// Validated end-to-end against:
//   - 10 `encrypt_decrypt` vectors (round-trip via public API + byte-equal
//     wire when nonce is injected via the test-only entry)
//   - 18 `long_encrypt_decrypt` vectors (SHA-256 of wire matches expected)
//   - 5  `decrypt_only` vectors (non-standard padding tolerance)
//   - All 19 `invalid_decryption` vectors map to the appropriate top-level
//     `NIP44v3.Error` case (vector 18 short-circuits at `Context.init`,
//     before any crypto runs).
//   - Random-nonce smoke test (no injection).
//   - Edge cases: empty plaintext, wrong-length keys.

import Foundation
import Security

extension NIP44v3 {

    /// Unified error type at the public boundary.
    ///
    /// Per-layer typed errors (`Keys.Error`, `Encryption.Error`,
    /// `Ciphertext.Error`, `Context.Error`) are mapped to this flat set at
    /// the public API boundary. Most callers — including NIP-46 dispatch in
    /// `LightSigner.swift` — only need to decide between:
    ///   - "input is malformed, reject early" (`.invalidKey`,
    ///     `.invalidContext`, `.invalidCiphertext`)
    ///   - "decryption failed, surface generic error to client"
    ///     (`.decryptionFailed`)
    ///   - "fall back to NIP-44 v2 / NIP-04" (`.unsupportedVersion`)
    ///
    /// Mirrors ncrypt-go's `errors.go`: only `ErrContextMismatch` and
    /// `ErrUnsupportedVersion` are EXPORTED there; the rest are unexported
    /// sentinels callers can't distinguish. We collapse `ErrContextMismatch`
    /// into `.decryptionFailed` because at the wire level a context mismatch
    /// is byte-indistinguishable from MAC tampering — exposing them
    /// separately would leak which one happened to a network attacker.
    ///
    /// The `.unsupportedVersion(byte:)` variant carries the offending byte
    /// so callers can decide whether to fall back to NIP-44 v2 (`0x02`) or
    /// NIP-04 (`0x04`).
    enum Error: Swift.Error, Equatable {
        /// Caller passed a malformed `seckey` / `pubkey` / `nonce` to the
        /// public API. Maps from any `Keys.Error` case.
        case invalidKey

        /// Caller-supplied `Context` had a non-UTF-8 scope. Maps from
        /// `Context.Error.scopeNotUTF8`. In practice this is rarely seen
        /// at the public API boundary because `Context.init` itself throws
        /// at construction time.
        case invalidContext

        /// Wire was structurally invalid: empty, `#`-prefix, base64 didn't
        /// decode, decoded payload was shorter than 77 bytes, scope length
        /// out of bounds, or chacha20_ct shorter than 4 bytes. Maps from
        /// `Ciphertext.Error` except `.unsupportedVersion`, which surfaces
        /// separately for fallback dispatch.
        case invalidCiphertext

        /// Wire version byte was not `0x03`. Carries the byte so callers
        /// can route `0x02` → NIP-44 v2 (LightCrypto) or `0x04` → NIP-04.
        /// `0x23` (`#`) is the spec-reserved sentinel for future non-base64
        /// encodings and also surfaces here.
        case unsupportedVersion(byte: UInt8)

        /// Decryption failed: MAC verify failed (could be tampering OR a
        /// caller-supplied context mismatch — these are intentionally
        /// indistinguishable), padding not all-zero, or post-parse size
        /// inconsistency. Maps from most `Encryption.Error` cases at
        /// decrypt time.
        case decryptionFailed

        /// Encryption failed pre-flight (plaintext exceeded 2^31 - 1 bytes,
        /// or system RNG failed). Maps from the encrypt-time subset of
        /// `Encryption.Error` plus `randomBytesFailed` for RNG failure.
        case encryptionFailed
    }

    // MARK: - Public encrypt

    /// Encrypts `plaintext` for `pubkey` with NIP-44 v3 using a freshly-
    /// generated random 32-byte nonce, returning the canonical base64 wire
    /// form.
    ///
    /// Composition (see per-layer files for algorithm detail):
    ///   1. Generate 32 random bytes for the nonce (`SecRandomCopyBytes`).
    ///   2. `Keys.derive(seckey, pubkey, nonce)` → encryptionKey + macKey.
    ///   3. `Encryption.encrypt(plaintext, encKey, macKey, context.kind,
    ///       context.scope, nonce)` → chacha20Ciphertext + mac.
    ///   4. `Ciphertext.encode(Parts(nonce, mac, kind, scope, chacha20Ct))`
    ///      → base64 wire.
    ///
    /// - Parameters:
    ///   - seckey: Local 32-byte secp256k1 secret key.
    ///   - pubkey: Remote 32-byte BIP-340 x-only public key.
    ///   - context: Pre-validated authenticated context (kind + UTF-8 scope).
    ///   - plaintext: Bytes to encrypt. May be empty. Max 2^31 - 1.
    /// - Returns: Base64-encoded wire ciphertext.
    /// - Throws: `NIP44v3.Error` mapped from the underlying layer's error.
    static func encrypt(
        seckey: Data,
        pubkey: Data,
        context: Context,
        plaintext: Data
    ) throws -> String {
        let nonce: Data
        do {
            nonce = try randomBytes(count: 32)
        } catch {
            throw Error.encryptionFailed
        }
        return try _encrypt(seckey: seckey, pubkey: pubkey, context: context, plaintext: plaintext, nonce: nonce)
    }

    // MARK: - Public decrypt

    /// Decrypts a base64 wire ciphertext for the caller-supplied `context`.
    /// Returns the recovered plaintext bytes.
    ///
    /// MAC verification is bound to `(context.kind, context.scope)`: a
    /// caller-supplied context that disagrees with the encrypted-in values
    /// fails MAC verify and surfaces as `.decryptionFailed`. This is the
    /// core security property — callers can't lie about context.
    ///
    /// Composition:
    ///   1. `Ciphertext.decode(ciphertext)` → `Parts` (or `invalidCiphertext`
    ///      / `unsupportedVersion`).
    ///   2. `Keys.derive(seckey, pubkey, parts.nonce)` → encryptionKey + macKey.
    ///   3. `Encryption.decrypt(parts.chacha20Ciphertext, parts.mac, encKey,
    ///      macKey, context.kind, context.scope, parts.nonce)` → plaintext.
    ///
    /// Spec algorithm step 4 ("Check the scope and kind to be what is
    /// expected"): the embedded `parts.kind` / `parts.scope` are compared
    /// against the caller-supplied `context.kind` / `context.scope` BEFORE
    /// MAC verify. MAC verify alone is insufficient — because our MAC
    /// computation uses caller context (which by construction matches what
    /// the encryptor signed in), a wire whose embedded kind/scope bytes are
    /// tampered but MAC tag is unchanged would otherwise silently decrypt
    /// successfully. Both check mismatches collapse to `.decryptionFailed`
    /// (same as MAC failure) so an outside observer can't oracle which
    /// kind of mismatch tripped the rejection.
    ///
    /// - Parameters:
    ///   - seckey: Local 32-byte secp256k1 secret key.
    ///   - pubkey: Remote 32-byte BIP-340 x-only public key.
    ///   - context: Caller's expected context. Bound into MAC verify.
    ///   - ciphertext: Base64-encoded wire ciphertext.
    /// - Returns: Recovered plaintext bytes.
    /// - Throws: `NIP44v3.Error` per the mapping in `mapError(_:)` below.
    static func decrypt(
        seckey: Data,
        pubkey: Data,
        context: Context,
        ciphertext: String
    ) throws -> Data {
        let parts: Ciphertext.Parts
        do {
            parts = try Ciphertext.decode(ciphertext)
        } catch let e as Ciphertext.Error {
            throw mapCiphertextError(e)
        }

        // Spec step 4 — embedded kind / scope must equal caller's context.
        // See doc comment above for why MAC verify alone isn't sufficient.
        // Both branches throw `.decryptionFailed` (same case as MAC failure)
        // so a wire-tampering observer can't tell whether they tripped a
        // kind mismatch, a scope mismatch, or a MAC mismatch.
        guard parts.kind == context.kind,
              constantTimeBytesEqual(parts.scope, context.scope) else {
            throw Error.decryptionFailed
        }

        let derived: Keys.Derived
        do {
            derived = try Keys.derive(seckey: seckey, pubkey: pubkey, nonce: parts.nonce)
        } catch let e as Keys.Error {
            throw mapKeysError(e)
        }

        do {
            return try Encryption.decrypt(
                chacha20Ciphertext: parts.chacha20Ciphertext,
                mac: parts.mac,
                encryptionKey: derived.encryptionKey,
                macKey: derived.macKey,
                kind: context.kind,
                scope: context.scope,
                nonce: parts.nonce
            )
        } catch let e as Encryption.Error {
            throw mapEncryptionDecryptError(e)
        }
    }

    /// Constant-time byte equality for the scope comparison in `decrypt`.
    /// `Data == Data` short-circuits on the first mismatching byte, which
    /// would leak the mismatch position via timing. XOR-fold + OR
    /// accumulator stays branch-free over the full length.
    ///
    /// (Encryption.swift has an internal `constantTimeEqual` for the MAC
    /// comparison; duplicated here rather than exported across layer
    /// boundaries because the duplication is a 12-line helper and exposing
    /// the per-layer crypto primitives across modules invites accidental
    /// non-crypto usage.)
    private static func constantTimeBytesEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var accum: UInt8 = 0
        a.withUnsafeBytes { aRaw in
            b.withUnsafeBytes { bRaw in
                let ap = aRaw.bindMemory(to: UInt8.self).baseAddress!
                let bp = bRaw.bindMemory(to: UInt8.self).baseAddress!
                for i in 0..<a.count {
                    accum |= ap[i] ^ bp[i]
                }
            }
        }
        return accum == 0
    }

    // MARK: - Test-only nonce-injection entry

    /// Test-only encrypt that accepts a caller-supplied nonce. Required to
    /// produce byte-exact wire output that matches the spec test vectors
    /// (each vector pins both the nonce and the resulting ciphertext).
    ///
    /// **Do not call from production code.** The `_testOnly_` prefix is the
    /// discipline marker. `internal` access keeps this out of the public
    /// API surface for any client of the Clave module; XCTest reaches it
    /// via `@testable import Clave`.
    ///
    /// Spec rationale (`implementing.md`): "Do not allow users to specify a
    /// custom nonce. This is required for the test vectors, but should be
    /// a strictly internal API that is disabled in a [non-DEBUG] build."
    /// We use `internal` access instead of a `#if DEBUG` gate because the
    /// standalone-`swift` CLI validation pipeline that gates layer ports
    /// doesn't define DEBUG — gating would prevent the very validation
    /// that proves the algorithm correct. The naming convention + module
    /// boundary is the safety net.
    internal static func _testOnly_encrypt(
        seckey: Data,
        pubkey: Data,
        context: Context,
        plaintext: Data,
        nonce: Data
    ) throws -> String {
        return try _encrypt(seckey: seckey, pubkey: pubkey, context: context, plaintext: plaintext, nonce: nonce)
    }

    // MARK: - Internal helpers

    /// Shared encrypt body used by both the public `encrypt` and the test-
    /// only `_testOnly_encrypt`. The only difference between the two
    /// entries is the source of `nonce`.
    private static func _encrypt(
        seckey: Data,
        pubkey: Data,
        context: Context,
        plaintext: Data,
        nonce: Data
    ) throws -> String {
        let derived: Keys.Derived
        do {
            derived = try Keys.derive(seckey: seckey, pubkey: pubkey, nonce: nonce)
        } catch let e as Keys.Error {
            throw mapKeysError(e)
        }

        let chacha20Ct: Data
        let mac: Data
        do {
            (chacha20Ct, mac) = try Encryption.encrypt(
                plaintext: plaintext,
                encryptionKey: derived.encryptionKey,
                macKey: derived.macKey,
                kind: context.kind,
                scope: context.scope,
                nonce: nonce
            )
        } catch let e as Encryption.Error {
            throw mapEncryptionEncryptError(e)
        }

        let parts = Ciphertext.Parts(
            nonce: nonce,
            mac: mac,
            kind: context.kind,
            scope: context.scope,
            chacha20Ciphertext: chacha20Ct
        )
        return Ciphertext.encode(parts)
    }

    /// Cryptographically-strong random bytes via `SecRandomCopyBytes`.
    /// Used for nonce generation in the public `encrypt` entry.
    private static func randomBytes(count: Int) throws -> Data {
        var buf = Data(count: count)
        let status = buf.withUnsafeMutableBytes { rawBuf -> OSStatus in
            guard let base = rawBuf.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else {
            throw Error.encryptionFailed
        }
        return buf
    }

    // MARK: - Error mapping

    private static func mapKeysError(_ e: Keys.Error) -> Error {
        switch e {
        case .invalidSecretKeyLength,
             .invalidPublicKeyLength,
             .invalidNonceLength,
             .invalidSecretKey,
             .ecdhFailed:
            return .invalidKey
        }
    }

    private static func mapCiphertextError(_ e: Ciphertext.Error) -> Error {
        switch e {
        case .unsupportedVersion(let byte):
            return .unsupportedVersion(byte: byte)
        case .empty,
             .ciphertextTooShort,
             .scopeLengthOutOfBounds,
             .chacha20CiphertextTooShort,
             .base64DecodeFailed:
            return .invalidCiphertext
        }
    }

    /// Mapping for the decrypt-time subset of Encryption errors. MAC,
    /// padding, post-parse size errors all collapse to `.decryptionFailed`
    /// because they are byte-indistinguishable to an outside observer and
    /// exposing them separately to callers would invite oracle attacks.
    /// Input-length errors stay as `.invalidKey` because they signal a
    /// caller-side bug, not a wire-level failure.
    private static func mapEncryptionDecryptError(_ e: Encryption.Error) -> Error {
        switch e {
        case .invalidEncryptionKeyLength,
             .invalidMacKeyLength,
             .invalidNonceLength:
            return .invalidKey
        case .plaintextTooLong,
             .ciphertextTooShort,
             .macInvalid,
             .paddingInvalid,
             .plaintextOutOfBounds:
            return .decryptionFailed
        }
    }

    /// Mapping for the encrypt-time subset of Encryption errors. Almost
    /// all map to `.encryptionFailed`; the input-key-length cases stay as
    /// `.invalidKey` for consistency with the decrypt path.
    private static func mapEncryptionEncryptError(_ e: Encryption.Error) -> Error {
        switch e {
        case .invalidEncryptionKeyLength,
             .invalidMacKeyLength,
             .invalidNonceLength:
            return .invalidKey
        case .plaintextTooLong:
            return .encryptionFailed
        case .ciphertextTooShort,
             .macInvalid,
             .paddingInvalid,
             .plaintextOutOfBounds:
            // Unreachable from encrypt path, but mapped for exhaustiveness.
            return .encryptionFailed
        }
    }
}
