import XCTest
@testable import Clave

/// Tests for `NIP44v3.Ciphertext.encode(...)` / `.decode(...)` (wire framing).
///
/// Validates the wire layout
///
///   version(1) || nonce(32) || mac(32) || u32_be(kind)(4) ||
///   u32_be(scope_len)(4) || scope(N) || chacha20_ct(rest)
///
/// against the NIP-44 v3 spec test-vectors.json at commit `5680754`
/// (2026-06-02). Categories exercised:
///
/// 1. `encrypt_decrypt` × 10 — encode round-trip: take the components
///    parsed out of the JSON wire, re-encode through `Ciphertext.encode`,
///    verify the resulting base64 string is byte-identical to the JSON.
/// 2. `encrypt_decrypt` × 10 — decode round-trip: feed the JSON wire into
///    `Ciphertext.decode`, verify the extracted nonce/kind/scope match the
///    JSON-supplied values (mac and chacha20_ct are not checked here — that
///    is the Encryption layer's job).
/// 3. `invalid_decryption` × 10 (indices 4-13) — wire-frame rejection
///    vectors. Each MUST throw a Ciphertext-layer error mapped to its
///    failure category (version, framing, base64).
/// 4. Spec edge cases — empty input, `#` prefix, the 76/77-byte boundary,
///    `chacha20_ct < 4`, scope-length-out-of-bounds.
///
/// Skipped (encryption-layer / context-layer chips own these):
///   - 0-3: MAC + padding tampering (encryption layer)
///   - 14-17: kind + scope mismatch (encryption layer)
///   - 18: UTF-8 invalid scope (context layer)
final class NIP44v3CiphertextTests: XCTestCase {

    // MARK: - Vector types

    private struct EncryptDecryptVector {
        let nonceHex: String
        let kind: UInt32
        let scopeHex: String
        let ciphertextB64: String
    }

    private enum InvalidWireCategory {
        case version
        case framing
        case base64
    }

    private struct InvalidWireVector {
        let ciphertextB64: String
        let why: String
        let category: InvalidWireCategory
    }

    // MARK: - encrypt_decrypt vectors (10) — only the wire-framing-relevant fields

    private static let encryptDecryptVectors: [EncryptDecryptVector] = [
        .init(nonceHex: "b5451a6d90ec575b4cdcedf4987429eeab1bbaa192ea3db89eafa058826885a6", kind: 1, scopeHex: "", ciphertextB64: "A7VFGm2Q7FdbTNzt9Jh0Ke6rG7qhkuo9uJ6voFiCaIWmMJrEDBNRRCorotVxmP7ge14Y+UtDn1/Pn3uzAaNNzHUAAAABAAAAAPJgoFXpn6mjFE0hUZrnZljeaYwSdqBKbVDXcyLgVGC8"),
        .init(nonceHex: "f99a4a4a84a4906d839b62861dcd54883cccabb3616d003f27250ac00e672c50", kind: 30078, scopeHex: "737065632e6e6f7374722e6c616e642f6e697034347633", ciphertextB64: "A/maSkqEpJBtg5tihh3NVIg8zKuzYW0APyclCsAOZyxQfHiK7t6u8D4JR3dRUKMpBRQzoOYtunePezG3p65AXPEAAHV+AAAAF3NwZWMubm9zdHIubGFuZC9uaXA0NHYzvgOo5isSBI06S531Yb9j9l+LpL9dA0D9/LLtorb866Y="),
        .init(nonceHex: "ffffd9144f5fe48077ac672e1366d303dfebdf60b1abd07fce1ff762bb25a4aa", kind: 1, scopeHex: "e381afe4b896e7958c", ciphertextB64: "A///2RRPX+SAd6xnLhNm0wPf699gsavQf84f92K7JaSqrm0b+bxgKBqNS04QURAmEXZlYBY9Ed4neDw2uOAqkGcAAAABAAAACeOBr+S4lueVjIEUNKR4ekMqHUoWb/ks495G0c1lD6oPQ3ZFsa4LHvRE"),
        .init(nonceHex: "726cab7f363afe8c0783dc1d2d6e4700ace52a26996a53ba3928ef3c865cc235", kind: 1, scopeHex: "efbbbfefbfbe", ciphertextB64: "A3Jsq382Ov6MB4PcHS1uRwCs5SommWpTujko7zyGXMI1d8FRsRgcGnjOo+Ifry8x/QC+vDDkPCHv7WDaem7tQ10AAAABAAAABu+7v++/vm+/pDQcUXHli2Do1EEoqYFmF/67UUcl31Ks9TRy9vCwc2IUY6Ev9T+oBanqVWGbPgAWysjisi5dIPAEcndMK2Ur4m2UqTo3WVTIqKmy30ad5VOwl4v1AHweiZvJU/w+lQ=="),
        .init(nonceHex: "ec64f769d99bc3c6f5231145b546334275d910e11fe9a11351ee487e4dbfd4ec", kind: 1, scopeHex: "ef8080", ciphertextB64: "A+xk92nZm8PG9SMRRbVGM0J12RDhH+mhE1HuSH5Nv9Tsg6J943ljpXnIaVIuHaXrWfa99RkqZOW6NGy6oqm2HocAAAABAAAAA++AgNCkiGZgN5Uzx1HVpcoLQQisIwWD32PqBoQ4T598/KmHsxUAGEARiXh9ikGXtwKuH8a8EzTcobkr4OEXfPs0h5u0A1HUJ3M/Hc/orcqZgeA0RhfZe3IASVmQfU9/pge+nTPjJVK5ZHOlEBnt7tmYcT8vqv9bpxbyhCBGMO6nEFhUtrr2IKCW3Z6vljg7T3FDr7aVIY/cxniq4E+e5ec9pZ+wn3j9PAibWgEANCDK5nyiH6B348lnqxfmu8bvzzyPhA=="),
        .init(nonceHex: "c027624d50656a34add75cec7e476e6287bc919cacf0ebbda6d3277c02b0a239", kind: 1, scopeHex: "", ciphertextB64: "A8AnYk1QZWo0rddc7H5HbmKHvJGcrPDrvabTJ3wCsKI5ZMf+aMW7P7Iz5qDghY+87TL5pZjNiykm0xpMKlkwITgAAAABAAAAAE2F94qgXOR+co8R41Vu04wLtkrI3Y5QJbVmutA5v1MkCgrLCmZAwNXhQsUnzUOuAPloXVQQdgQL4gmVgIz0rqQ="),
        .init(nonceHex: "0da18d3ebcc5f269f6415e3e3fcb5e1a8d76318fe439ec83cfdf99ef8eaacee9", kind: 30078, scopeHex: "737065632e6e6f7374722e6c616e642f6e697034347633", ciphertextB64: "Aw2hjT68xfJp9kFePj/LXhqNdjGP5Dnsg8/fme+Oqs7p+xyexXUdk8ZJ2rtLWT1xQ9lXxWSiagEVpRg35PndmKQAAHV+AAAAF3NwZWMubm9zdHIubGFuZC9uaXA0NHYzuKZ6xxWsljlgBA/i6yz7+dmE6dyszU9qkR7f2xDUQdg="),
        .init(nonceHex: "8b3c3f3aaf575328259ac5e3c08191dde308c573e3f4e7cda7042f82133143fb", kind: 1, scopeHex: "e381afe4b896e7958c", ciphertextB64: "A4s8PzqvV1MoJZrF48CBkd3jCMVz4/TnzacEL4ITMUP7b2QxXAKNEKp93ebvTrmrJ4aeJtLvqRokEeGXPBLE9UsAAAABAAAACeOBr+S4lueVjO04T51hx+sZw9n3gheEAyVOP0w/pWFvFtCuolpBkHvk"),
        .init(nonceHex: "20c635f2f795178ea0bbf9856dd99da02138ba79337d2511d887f2a065b917c9", kind: 1, scopeHex: "efbbbfefbfbe", ciphertextB64: "AyDGNfL3lReOoLv5hW3ZnaAhOLp5M30lEdiH8qBluRfJTmsWPfIzALsx5OokjdKYAWkgDkES88FoC4k6wtgxUK8AAAABAAAABu+7v++/vmSE/qHW8+XDY97+8EQCRVPzORPYKrnLM6mNRp+zl2C6"),
        .init(nonceHex: "a05a11dcd50aa1e855b7e11a816158a1a4827d21a00b60105ed3c8e802770d77", kind: 1, scopeHex: "ef8080", ciphertextB64: "A6BaEdzVCqHoVbfhGoFhWKGkgn0hoAtgEF7TyOgCdw13O273WC9FSDyMtfOYNFvOlZQcaSrLdo6WBQ7ZI2UWn5MAAAABAAAAA++AgPPJWHFZya+M6arLz4wrWMHfL4Wyv4gYZBkicAvVBX0dMsr5tBcTP5xaM4lJZZnokEvMZRzYbjrfNTjT2gCWBapNdr/QrHxlTDa54nRmVR/2GBLkmQ5QeIiDm6OhfjXyYA=="),
    ]

    // MARK: - invalid_decryption vectors (indices 4-13: wire-frame-rejection subset)

    private static let invalidWireVectors: [InvalidWireVector] = [
        // 4 — '#' prefix on the base64 input
        .init(ciphertextB64: "#A2A/tbfDDqn4qx267aPFZDwyH78j9zZV8g8ekZKonH8bDR7vYhp7zzh3oJAlJWem/Z5OVrRvUAJQrx8q289PqsEAAAABAAAACeOBr+S4lueVjASdOe8pTxevoZoYq1Y8rRarB6+yzRlquT4RZlmHH3jLEQmAbBjQGrOXi1uWPbaKC8j/VpjW5S9BAtyMSMpUcHg=", why: "unsupported future version", category: .version),
        // 5 — decoded[0] == 0x00
        .init(ciphertextB64: "AP9SHg4CFoD4fy22vSMNZV+efP7Ld7GCOpIKeZANqL+Kspe380sGxRQGKyy/liCuMi8DbcfQJypivkS+Y/bz3sIAAAABAAAACeOBr+S4lueVjMM0jKIQIfjKuEBBmjWPFmQsB20qe5pcJiLpnnXmp12z", why: "unsupported version 0", category: .version),
        // 6 — decoded[0] == 0x02
        .init(ciphertextB64: "Ap2Mv1HTQrVArE2UVevKq7rQ+a0FMw8OBuiAMnA81jJit7c0QzkEMr/o+5++t0/FbXFABfQaTRpF+dBuISyw3rEAAAABAAAAAC5e+Y9lfvgD1trmXL2Jv5H3Khi8ayWJJQMrVOEMd9tlJNj1b7k/ZzIG71f2GBzzoeBImA2fk+q6Iix4v5jUulo=", why: "unsupported version 2", category: .version),
        // 7 — decoded[0] == 0x04
        .init(ciphertextB64: "BAahtRKP0WL8luCz9m6TydiQtWUfoIWvkRlg2tatPVOCAwYrO8Dw3DZMgeTGjaehohfAmVyZ6SneuTQF3Ho+EUIAAHV+AAAAF3NwZWMubm9zdHIubGFuZC9uaXA0NHYzpHJCeyhgMaqIsPgWO635BaIwmRU4cfe9aA6gGqGI7SY=", why: "unsupported version 4", category: .version),
        // 8 — empty payload
        .init(ciphertextB64: "", why: "empty payload", category: .framing),
        // 9 — payload is just one byte (`Aw==` → 0x03)
        .init(ciphertextB64: "Aw==", why: "payload only has 1 byte", category: .framing),
        // 10 — scope length out of bounds
        .init(ciphertextB64: "A6oBqSSHPckKYt8Doymo2s1ku7LJxSNSfSuQdBoXaRe8q+5FQmvwbejIzJEaVKdUhbykNt5VFxno+sZtreNhrHgAAAABAAAVCO+AgAnTQMJrGJX7muna+wwIyM82vR398H+fhL6XxOam03jQErUC9W+klrNflk6oJ4mmyO88x6FJcf6n6LfDpGjMogNuMxoR1crWfknPMJuHggEUfOU6AjN7CgGiFPdnfcgbUPP487vxX9iw7U8WhQCfnh46vQTdwCDIm0C3aUp2/fJ0xNTVIZkFVKV1CyvyFpVicY9Zc7fmeEIDAsJvM1beK9sWqp9CI/sMU9OXmTfjdugSuisDRevchLkr6h5kB/rXDw==", why: "scope length out-of-bounds", category: .framing),
        // 11 — chacha20_ct < 4 bytes
        .init(ciphertextB64: "A/uzxqp0UwE6j7p8PIRKJDa0ah39GGyMbM0fOivlqESqbfFnp5OD2FSHR9TOTeJwiAfLXcXkoZPwiNKjB4ZgXV4AAAABAAAABu+7v++/vm7l8A==", why: "ciphertext too short", category: .framing),
        // 12 — base64 trailing garbage (`!`)
        .init(ciphertextB64: "A5jnLthci6SRC9V9Ak/AKGyB7xAGPLGZx+fW9wjfvOKQuug5cUUGX4R0mmxFHl5/TtcQ4syIiTtgXL3uVveIP3MAAHV+AAAAF3NwZWMubm9zdHIubGFuZC9uaXA0NHYzS3rEqFHqpL5Yqh/xY+a9i0XAyY960LDSfzQjSZh4UHzbuxmMEk92jAczsFkI9cWqd+xzahX59yD9l+UnCw3o9yXmzZIaA6UYPFI20f2VnH+G6F0Zt917fgt0bJwR3QUwblT63eOKLJGYhXqC11dweuKORW6oGJagRFo7P8r3UIFTHPkL5xMhUtZS7TS7GDKTB7kmEp5trwfzboiWxzp12LSlkUU9Nctyf6KE4iEQbk2jDndbC9npCn1rFpsFiHsd!", why: "invalid base64 (trailing)", category: .base64),
        // 13 — base64 middle garbage (`%`)
        .init(ciphertextB64: "A3oG29gbEA%8QXjVLA5JeYOl1Hj5bJVaNcl2tAnfEHm5pzS0V+3eF8Tns8+A+TkfxrSc3DuAbkxc9SgWC+214cBIAAAABAAAACeOBr+S4lueVjGfB4CLk22vLao5NE6OH5KlgzSy++iyD7FZEmAkCVOfQkrnbj9kzyLF7HRygI5E2FJdeQkX6WDiHtwzP/UWwd+cnMaXTYS7vL0Zh6Lvz/PKicCecxB0NvkAdYM3hOpodhXEYd2nano+37mU1Cahp2uwyygJQTb427cHBucQiVpIadVoKqMeIA7EGvO9HTgTxgE93vyT26NqZFO9aniV1bFc7y9nq1OYHFfNQgzdxVMTQ88SwMbq2TSpU5uJc/cphNA==", why: "invalid base64 (middle)", category: .base64),
    ]

    // MARK: - 1. Encode round-trip

    /// For each `encrypt_decrypt` vector, manually parse the JSON wire to
    /// extract the components, build a `Ciphertext.Parts` struct, re-encode
    /// through the public API, and verify the resulting base64 string is
    /// byte-identical to the JSON ciphertext.
    func testEncodeRoundTrip() throws {
        var failures: [String] = []
        for (i, vec) in Self.encryptDecryptVectors.enumerated() {
            do {
                let wire = try Self.decodeBase64(vec.ciphertextB64)
                let parsed = try Self.manualParseWire(wire)

                let nonceHex = try Self.hex(vec.nonceHex)
                let scope = try Self.hex(vec.scopeHex)

                XCTAssertEqual(parsed.nonce, nonceHex, "vec[\(i)] manual parse: nonce mismatch")
                XCTAssertEqual(parsed.kind, vec.kind, "vec[\(i)] manual parse: kind mismatch")
                XCTAssertEqual(parsed.scope, scope, "vec[\(i)] manual parse: scope mismatch")

                let parts = NIP44v3.Ciphertext.Parts(
                    nonce: parsed.nonce,
                    mac: parsed.mac,
                    kind: parsed.kind,
                    scope: parsed.scope,
                    chacha20Ciphertext: parsed.chacha20Ciphertext
                )
                let encoded = NIP44v3.Ciphertext.encode(parts)
                if encoded != vec.ciphertextB64 {
                    failures.append("vec[\(i)] encode mismatch: got \(encoded.prefix(40))..., want \(vec.ciphertextB64.prefix(40))...")
                }
            } catch {
                failures.append("vec[\(i)] threw \(error)")
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) encode-round-trip failures:\n" + failures.prefix(10).joined(separator: "\n"))
    }

    // MARK: - 2. Decode round-trip

    /// For each `encrypt_decrypt` vector, run `Ciphertext.decode` and verify
    /// the extracted nonce/kind/scope match the JSON values. mac and
    /// chacha20_ct are not value-checked here (Encryption-layer concern) —
    /// we only verify they were parsed into the correct slots by checking
    /// their lengths and that re-encoding round-trips.
    func testDecodeRoundTrip() throws {
        var failures: [String] = []
        for (i, vec) in Self.encryptDecryptVectors.enumerated() {
            do {
                let parts = try NIP44v3.Ciphertext.decode(vec.ciphertextB64)
                let expectedNonce = try Self.hex(vec.nonceHex)
                let expectedScope = try Self.hex(vec.scopeHex)

                if parts.nonce != expectedNonce {
                    failures.append("vec[\(i)] nonce mismatch")
                }
                if parts.kind != vec.kind {
                    failures.append("vec[\(i)] kind mismatch: got \(parts.kind), want \(vec.kind)")
                }
                if parts.scope != expectedScope {
                    failures.append("vec[\(i)] scope mismatch: got \(parts.scope.hex), want \(expectedScope.hex)")
                }
                if parts.mac.count != 32 {
                    failures.append("vec[\(i)] mac wrong size: \(parts.mac.count)")
                }
                if parts.chacha20Ciphertext.count < 4 {
                    failures.append("vec[\(i)] chacha20_ct shorter than 4 bytes")
                }

                // Round-trip: encode the decoded parts and confirm it equals the input.
                let reencoded = NIP44v3.Ciphertext.encode(parts)
                if reencoded != vec.ciphertextB64 {
                    failures.append("vec[\(i)] reencoded != original")
                }
            } catch {
                failures.append("vec[\(i)] threw \(error)")
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) decode-round-trip failures:\n" + failures.prefix(10).joined(separator: "\n"))
    }

    // MARK: - 3. Invalid wire rejection

    /// Each of the 10 wire-frame-rejection vectors (indices 4-13 in the spec
    /// `invalid_decryption` set) MUST throw a Ciphertext-layer error matching
    /// its failure category.
    func testRejectsInvalidWireVectors() throws {
        var failures: [String] = []
        for (i, vec) in Self.invalidWireVectors.enumerated() {
            do {
                _ = try NIP44v3.Ciphertext.decode(vec.ciphertextB64)
                failures.append("vec[\(i)] (\(vec.why)) UNEXPECTEDLY SUCCEEDED")
            } catch let error as NIP44v3.Ciphertext.Error {
                switch (vec.category, error) {
                case (.version, .unsupportedVersion):
                    break
                case (.framing, .empty),
                     (.framing, .ciphertextTooShort),
                     (.framing, .scopeLengthOutOfBounds),
                     (.framing, .chacha20CiphertextTooShort):
                    break
                case (.base64, .base64DecodeFailed):
                    break
                default:
                    failures.append("vec[\(i)] (\(vec.why)) wrong error: got \(error), category \(vec.category)")
                }
            } catch {
                failures.append("vec[\(i)] (\(vec.why)) non-Ciphertext error: \(error)")
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) invalid-wire-rejection failures:\n" + failures.prefix(10).joined(separator: "\n"))
    }

    // MARK: - 4. Spec edge cases

    func testEmptyInputThrowsEmpty() {
        do {
            _ = try NIP44v3.Ciphertext.decode("")
            XCTFail("expected .empty")
        } catch let error as NIP44v3.Ciphertext.Error {
            XCTAssertEqual(error, .empty)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// The spec reserves `ciphertext[0] == '#'` for non-base64 future
    /// encodings. We check on the FIRST BYTE OF THE INPUT STRING before
    /// any base64 decoding (per ncrypt-go).
    func testHashPrefixThrowsUnsupportedVersion() {
        do {
            _ = try NIP44v3.Ciphertext.decode("#")
            XCTFail("expected .unsupportedVersion(0x23)")
        } catch let error as NIP44v3.Ciphertext.Error {
            XCTAssertEqual(error, .unsupportedVersion(byte: 0x23))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// 76 bytes decoded → one byte short of the 77-byte minimum.
    func test76ByteInputIsCiphertextTooShort() {
        let raw = Data(repeating: 0x03, count: 76)
        let b64 = raw.base64EncodedString()
        do {
            _ = try NIP44v3.Ciphertext.decode(b64)
            XCTFail("expected .ciphertextTooShort")
        } catch let error as NIP44v3.Ciphertext.Error {
            XCTAssertEqual(error, .ciphertextTooShort)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// 77 bytes total = 73-byte header + 0-byte scope + 4-byte chacha20_ct.
    /// This is the minimum wire that passes both the `< 77` length check and
    /// the `chacha20_ct < 4` check, so it must succeed.
    func test77ByteMinimumIsAccepted() throws {
        var wire = Data()
        wire.append(0x03)                                    // version
        wire.append(Data(repeating: 0xaa, count: 32))        // nonce
        wire.append(Data(repeating: 0xbb, count: 32))        // mac
        wire.append(contentsOf: [0, 0, 0, 1])                // kind = 1
        wire.append(contentsOf: [0, 0, 0, 0])                // scope_len = 0
        wire.append(Data(repeating: 0xcc, count: 4))         // chacha20_ct (4 bytes)
        XCTAssertEqual(wire.count, 77)

        let parts = try NIP44v3.Ciphertext.decode(wire.base64EncodedString())
        XCTAssertEqual(parts.nonce.count, 32)
        XCTAssertEqual(parts.mac.count, 32)
        XCTAssertEqual(parts.kind, 1)
        XCTAssertEqual(parts.scope.count, 0)
        XCTAssertEqual(parts.chacha20Ciphertext.count, 4)
    }

    /// 77 bytes total but scope_len = 1, so chacha20_ct length = 77-73-1 = 3.
    /// The `chacha20_ct >= 4` check must reject.
    func testChacha20CiphertextTooShortIsRejected() {
        var wire = Data()
        wire.append(0x03)
        wire.append(Data(repeating: 0xaa, count: 32))
        wire.append(Data(repeating: 0xbb, count: 32))
        wire.append(contentsOf: [0, 0, 0, 1])
        wire.append(contentsOf: [0, 0, 0, 1])                // scope_len = 1
        wire.append(0xdd)                                    // scope (1 byte)
        wire.append(Data(repeating: 0xcc, count: 3))         // chacha20_ct (3 bytes)
        XCTAssertEqual(wire.count, 77)

        do {
            _ = try NIP44v3.Ciphertext.decode(wire.base64EncodedString())
            XCTFail("expected .chacha20CiphertextTooShort")
        } catch let error as NIP44v3.Ciphertext.Error {
            XCTAssertEqual(error, .chacha20CiphertextTooShort)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// 80 bytes total, scope_len = 100 (clearly larger than 80 - 73 = 7 bytes remaining).
    func testScopeLengthOutOfBoundsIsRejected() {
        var wire = Data()
        wire.append(0x03)
        wire.append(Data(repeating: 0xaa, count: 32))
        wire.append(Data(repeating: 0xbb, count: 32))
        wire.append(contentsOf: [0, 0, 0, 1])
        wire.append(contentsOf: [0, 0, 0, 100])              // scope_len = 100
        wire.append(Data(repeating: 0xee, count: 7))         // trailing junk
        XCTAssertEqual(wire.count, 80)

        do {
            _ = try NIP44v3.Ciphertext.decode(wire.base64EncodedString())
            XCTFail("expected .scopeLengthOutOfBounds")
        } catch let error as NIP44v3.Ciphertext.Error {
            XCTAssertEqual(error, .scopeLengthOutOfBounds)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// Raw-bytes API path: an empty `Data` should be rejected.
    func testDecodeBytesRejectsEmpty() {
        do {
            _ = try NIP44v3.Ciphertext.decodeBytes(Data())
            XCTFail("expected error")
        } catch let error as NIP44v3.Ciphertext.Error {
            XCTAssertEqual(error, .ciphertextTooShort)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// `encodeBytes` should produce the raw wire (pre-base64) — the same bytes
    /// that `decodeBytes` consumes. Pure round-trip on a synthetic message.
    func testEncodeBytesDecodeBytesRoundTrip() throws {
        let parts = NIP44v3.Ciphertext.Parts(
            nonce: Data(repeating: 0x01, count: 32),
            mac: Data(repeating: 0x02, count: 32),
            kind: 12345,
            scope: Data([0xde, 0xad, 0xbe, 0xef]),
            chacha20Ciphertext: Data(repeating: 0x99, count: 20)
        )
        let raw = NIP44v3.Ciphertext.encodeBytes(parts)
        XCTAssertEqual(raw.first, 0x03)
        XCTAssertEqual(raw.count, 1 + 32 + 32 + 4 + 4 + 4 + 20)

        let decoded = try NIP44v3.Ciphertext.decodeBytes(raw)
        XCTAssertEqual(decoded, parts)
    }

    // MARK: - Helpers

    private static func hex(_ s: String) throws -> Data {
        guard let d = Data(hexString: s) else {
            throw NSError(domain: "NIP44v3CiphertextTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad hex: \(s.prefix(40))"])
        }
        return d
    }

    private static func decodeBase64(_ s: String) throws -> Data {
        guard let d = Data(base64Encoded: s) else {
            throw NSError(domain: "NIP44v3CiphertextTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "bad base64: \(s.prefix(40))"])
        }
        return d
    }

    private struct ManuallyParsed {
        let version: UInt8
        let nonce: Data
        let mac: Data
        let kind: UInt32
        let scope: Data
        let chacha20Ciphertext: Data
    }

    /// Independent reference parser used to validate `Ciphertext.encode` output
    /// without depending on `Ciphertext.decode`. Same byte-layout logic as the
    /// inline `parseWire` in `NIP44v3EncryptionTests.swift` (lines 376-425).
    private static func manualParseWire(_ data: Data) throws -> ManuallyParsed {
        guard data.count >= 73 else {
            throw NSError(domain: "NIP44v3CiphertextTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "wire too short"])
        }
        let base = data.startIndex
        let version = data[base]
        let nonce = Data(data[(base + 1)..<(base + 33)])
        let mac = Data(data[(base + 33)..<(base + 65)])
        let kind = readU32BE(data, offset: base + 65)
        let scopeLen = Int(readU32BE(data, offset: base + 69))
        let scopeStart = base + 73
        let scopeEnd = scopeStart + scopeLen
        guard scopeEnd <= data.endIndex else {
            throw NSError(domain: "NIP44v3CiphertextTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "scope length out of bounds"])
        }
        let scope = Data(data[scopeStart..<scopeEnd])
        let chacha = Data(data[scopeEnd..<data.endIndex])
        return ManuallyParsed(version: version, nonce: nonce, mac: mac, kind: kind, scope: scope, chacha20Ciphertext: chacha)
    }

    private static func readU32BE(_ d: Data, offset: Data.Index) -> UInt32 {
        var v: UInt32 = 0
        v |= UInt32(d[offset]) << 24
        v |= UInt32(d[offset + 1]) << 16
        v |= UInt32(d[offset + 2]) << 8
        v |= UInt32(d[offset + 3])
        return v
    }
}
