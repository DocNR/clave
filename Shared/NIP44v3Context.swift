// NIP-44 v3 authenticated-context type.
//
// Spec: https://github.com/nostr-land/nip44v3/blob/main/nip44v3.md
// Pinned to commit 5680754 (2026-06-02).
// Reference impl: https://github.com/nostr-land/ncrypt-go (BSD-3).
//
// Layer: Context — `{kind: UInt32, scope: Data}` paired into the MAC's
// authenticated prefix. Validates that `scope` is well-formed UTF-8 per
// `implementing.md`: *"Do not canonicalize or otherwise transform the
// provided scope, and reject scopes that are not valid UTF-8."*
//
// Validated against `invalid_decryption` vector 18 from the spec
// test-vectors.json (scope_hex "ff", `why: "invalid scope (not valid utf8)"`)
// plus a handful of UTF-8 corpus cases.

import Foundation

extension NIP44v3 {

    /// Authenticated additional data bound into the NIP-44 v3 MAC.
    ///
    /// Two fields, both authenticated but NOT encrypted:
    ///   - `kind`: the Nostr event kind the message belongs to.
    ///   - `scope`: an application-specific UTF-8 byte string. May be empty.
    ///
    /// `Context` is value-type, `Equatable`, and immutable once constructed.
    /// Construction validates UTF-8; once you have a `Context` instance, its
    /// scope is guaranteed UTF-8 — no re-check is needed at use sites.
    ///
    /// Spec text from `implementing.md`:
    ///   - "Do not canonicalize or otherwise transform the provided scope"
    ///   - "reject scopes that are not valid UTF-8"
    ///
    /// So bytes pass through unchanged after the validation gate. No NFC
    /// normalization, no whitespace trim, no case fold.
    struct Context: Equatable {

        /// Event kind. Bound into the MAC's authenticated prefix as `u32_be`.
        let kind: UInt32

        /// Application-specific scope bytes. Guaranteed UTF-8 after init.
        /// Bound into the MAC as `u32_be(scope.count) || scope`.
        let scope: Data

        /// Per-layer errors. Mapped to `NIP44v3.Error.invalidContext` at the
        /// public boundary where appropriate; tests covering the spec
        /// `invalid_decryption[18]` vector match this case directly.
        enum Error: Swift.Error, Equatable {
            /// Scope bytes are not valid UTF-8 per the spec.
            case scopeNotUTF8
        }

        /// Constructs a Context with a binary scope.
        ///
        /// - Parameters:
        ///   - kind: Event kind.
        ///   - scope: Application-specific scope bytes. MUST be valid UTF-8.
        ///     Pass `Data()` for empty scope (the common case for non-
        ///     parameterized kinds), or prefer the `init(kind:)` convenience.
        /// - Throws: `Error.scopeNotUTF8` if `scope` is not valid UTF-8.
        init(kind: UInt32, scope: Data) throws {
            // Empty data is trivially valid UTF-8 — short-circuit so the
            // `init(kind:)` convenience never has to take the throwing path.
            if !scope.isEmpty {
                guard String(data: scope, encoding: .utf8) != nil else {
                    throw Error.scopeNotUTF8
                }
            }
            self.kind = kind
            self.scope = scope
        }

        /// Constructs a Context with an empty scope. The common case for
        /// kinds that don't carry a parameterized `d` tag (e.g. kind 1, 4,
        /// 1059). Non-throwing because empty data is trivially UTF-8 valid.
        init(kind: UInt32) {
            self.kind = kind
            self.scope = Data()
        }
    }
}
