# Tier 1 — Key Backup & Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement Tier 1 of the Amber-parity gap analysis per [`2026-05-22-key-backup-and-recovery-design.md`](../specs/2026-05-22-key-backup-and-recovery-design.md). **Phase 1**: encrypted-key export (NIP-49 `ncryptsec`), seed-phrase backup &amp; restore (NIP-06 mnemonic), QR export, restore flows, and backup-status surfacing — the complete manual-backup story. **Phase 2**: opt-in encrypted iCloud backup via CloudKit private DB (passphrase never leaves the device).

**Architecture:** Phase 1 is self-contained in the main app — no proxy, no NSE, no relay work. New code lives under `Clave/Backup/` (crypto + storage) and `Clave/Views/Backup/` (UI). The signing hot path is untouched: the working key stays `ThisDeviceOnly` in the Keychain exactly as today; the NSE keeps reading the same entry. Phase 2 adds a CloudKit container + entitlement; the working key still never enters iCloud — only the passphrase-encrypted `ncryptsec` blob does.

**Tech Stack:** Swift / SwiftUI on iOS, XCTest, `nostr-sdk-swift` 0.44.2 (already linked — provides `EncryptedSecretKey` for NIP-49 and `Keys.fromMnemonic` for NIP-06 derivation), `LocalAuthentication` (already used), `CryptoKit` (Phase 1 only for `SHA256` in the BIP-39 checksum), `CloudKit` (Phase 2 only). **No third-party crypto dep** — the BIP-39 entropy→words helper is hand-rolled (~80 lines + the canonical English wordlist as a checked-in Swift constant), consistent with the project's `Shared/Light*` self-contained crypto pattern.

**Branch:** Implementation lands in **two PRs**, one per phase, each branching off `main` separately when ready. Phase 1 is independently shippable and closes the largest gap on its own; Phase 2 layers on top.

**Verification model:** `xcodebuild` unit tests for crypto primitives (BIP-39 with reference test vectors, NIP-49 round-trip, NIP-06 derivation against a known mnemonic), pure-data tests for model/persistence changes, and a smoke-test pass on a real device at the end of each phase (biometric-gated mnemonic storage requires a device; iCloud requires a signed-in iCloud account). Per the repo README, the canonical test invocation is:

```
xcodebuild test -project Clave.xcodeproj -scheme Clave \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:ClaveTests/<TargetClass>
```

The simulator name is whatever's available on the build machine — substitute as needed. Pre-commit hooks should NOT be skipped; if a hook fails, fix the underlying issue.

**Commit model:** Per-task commits within each phase, TDD shape (red → green → commit). Conventional commits matching the existing repo style: `feat(backup): ...`, `refactor(backup): ...`, `test(backup): ...`, `docs(backup): ...`. Each commit ends with the harness session footer (`https://claude.ai/code/session_011AATP4KC3JVkuBvLCtL5zx`); substitute the repo's standard `Co-Authored-By` trailer if your tooling expects it.

**Reading order:** Read the spec end-to-end before Task 1. Re-read the spec's "Capability 4 — Encrypted iCloud backup" section before Phase 2 Task 1. The spec is authoritative for "why"; this plan is authoritative for "how" sequencing.

---

## File structure

### Phase 1 — Manual encrypted backup

**Created:**

- `Clave/Backup/BIP39Wordlist.swift` — the canonical 2048-word English BIP-39 wordlist as a `static let [String]`
- `Clave/Backup/BIP39.swift` — entropy → 12/24-word mnemonic generator + validation; relies on `BIP39Wordlist`
- `Clave/Backup/NIP49.swift` — thin convenience wrapper around `nostr-sdk-swift`'s `EncryptedSecretKey` (explicit `logN` / `KeySecurity`; bech32 in/out)
- `Clave/Backup/NIP06.swift` — convenience wrapper around `Keys.fromMnemonic` at path `m/44'/1237'/0'/0/0`
- `Clave/Backup/MnemonicStorage.swift` — per-pubkey biometric-gated Keychain entry for the mnemonic (separate service from the working key)
- `Clave/Models/BackupStatus.swift` — `enum BackupStatus { case notBackedUp, confirmed, skipped }` + per-account persistence helpers
- `Clave/Views/Backup/PassphraseEntry.swift` — reusable entry + confirm + strength meter + `logN` selector
- `Clave/Views/Backup/EncryptedBackupView.swift` — encrypted-backup result (ncryptsec text + Copy + QR)
- `Clave/Views/Backup/SeedWordsView.swift` — biometric-gated 12-word display
- `Clave/Views/Backup/SeedWordsImportView.swift` — 12-word entry with per-word wordlist validation
- `Clave/Views/Backup/EncryptedBackupImportView.swift` — ncryptsec + passphrase entry → decrypt
- `Clave/Views/Backup/BackupConfirmStep.swift` — onboarding "write down + verify 3 random words" gate

**Modified:**

- `Clave/AppState+AccountManager.swift` — `create()` switches to mnemonic-based generation; new `importMnemonic(words:)` and `importEncryptedKey(ncryptsec:passphrase:)` methods; existing `addAccount(nsec:)` stays
- `Clave/Views/Settings/ExportKeySheet.swift` — full refactor into the three-option "backup hub" (encrypted / seed words / raw nsec demoted)
- `Clave/Views/Settings/AccountDetailView.swift` — add Backup section (status + "Back up now" CTA)
- `Clave/Views/Home/AddAccountSheet.swift` — add a restore-mode selector (Paste nsec / Seed words / Encrypted backup)
- `Clave/Views/Onboarding/OnboardingView.swift` — route generated keys through `BackupConfirmStep`
- `Clave/Views/Home/SlimIdentityBar.swift` — small "backup needed" badge when current account is `.notBackedUp`
- `Shared/SharedStorage.swift` — `getBackupStatus(for:) / setBackupStatus(_:for:)` helpers
- `Shared/SharedConstants.swift` — `keychainServiceMnemonic` constant (distinct from `keychainService`)
- `README.md` — update "What works end-to-end" with the new backup capabilities

**Test files created:**

- `ClaveTests/BIP39Tests.swift` — wordlist length + sort + checksum + the Trezor BIP-39 test vectors round-trip
- `ClaveTests/NIP49WrapperTests.swift` — encrypt/decrypt round-trip + `KeySecurity` policy (`.medium` for generated, `.unknown` for imported)
- `ClaveTests/NIP06WrapperTests.swift` — derive a known npub from a known mnemonic via the NIP-06 path
- `ClaveTests/BackupStatusTests.swift` — codable + per-account persistence
- `ClaveTests/AccountManagerImportTests.swift` — `importMnemonic` and `importEncryptedKey` round-trip with stored mnemonic / encrypted blob

### Phase 2 — Encrypted iCloud backup

**Created:**

- `Clave/Backup/CloudKitBackup.swift` — `CKBackupRecord` model + `iCloudBackupService` (save / list / delete / fetch from `CKContainer.privateCloudDatabase`)
- `Clave/Views/Backup/iCloudBackupToggle.swift` — opt-in toggle row (used in `AccountDetailView`)
- `Clave/Views/Backup/iCloudRestoreView.swift` — list records from iCloud + multi-select + passphrase decrypt

**Modified:**

- `Clave/Clave.entitlements` — add `com.apple.developer.icloud-services` (`CloudKit`) + container identifier
- `Clave/Views/Settings/AccountDetailView.swift` — add iCloud toggle + status row inside the Backup section from Phase 1
- `Clave/Views/Home/AddAccountSheet.swift` — add "Restore from iCloud" option
- `Clave/AppState+AccountManager.swift` — `restoreFromiCloud(record:passphrase:)` method
- `docs/integrations.md` — note the new restore options client developers might encounter (informational)

**Test files created:**

- `ClaveTests/CKBackupRecordTests.swift` — codable round-trip; record-id derivation from pubkey
- `ClaveTests/iCloudBackupServiceTests.swift` — service contract using a mocked CloudKit interface (`CKContainerProtocol`)

---

## Phase 1 — Manual encrypted backup (NIP-49 + NIP-06)

**Goal of this phase:** ship the complete *manual* backup story — encrypted export, seed words for new keys, QR, restore from either format, onboarding backup gate, and per-account backup-status surfacing. After Phase 1, a user who loses their device can recover identity from a written-down seed phrase or a stored `ncryptsec` + passphrase. The signing hot path (NSE wake → Keychain → sign) is byte-identical to today.

**Estimated total tasks:** 16.

**Phase 1 acceptance criteria:**

- A newly-generated account produces a 12-word BIP-39 mnemonic; the user is walked through write-down + verify-3-random-words before reaching Home
- An existing/imported key (no mnemonic) shows seed words disabled with the correct messaging in `ExportKeySheet`
- `ExportKeySheet` produces a valid bech32 `ncryptsec` that round-trips via an independent NIP-49 implementation (use the rust-nostr CLI or a reference test vector)
- The same `ncryptsec` is restorable in `AddAccountSheet` → "Encrypted backup" with the user's passphrase, producing the same npub
- Seed words restored in `AddAccountSheet` → "Seed words" produce the same npub as the original generation
- `BackupStatus` flips from `.notBackedUp` → `.confirmed` after the onboarding confirmation step; the "backup needed" badge on `SlimIdentityBar` disappears
- The working key is still stored `ThisDeviceOnly` in the Keychain (`SharedKeychain.swift` unchanged in the at-rest path); the NSE signing path passes existing tests with zero regressions
- Smoke test on a real device: generate account → verify mnemonic shown → confirm 3 words → export ncryptsec → wipe app → restore from seed words → npub matches; repeat restore from ncryptsec

### Task 1: BIP-39 wordlist + entropy→words generator

**Files:**

- Create: `Clave/Backup/BIP39Wordlist.swift`
- Create: `Clave/Backup/BIP39.swift`
- Test: `ClaveTests/BIP39Tests.swift`

Hand-rolled per the spec — public test vectors mean zero ambiguity and we own the surface. The wordlist is the canonical English BIP-39 list (Trezor reference, 2048 words, alphabetically sorted). The generator does entropy → words ONLY; words → seed → keys is handled by `Keys.fromMnemonic` (Task 4).

- [ ] **Step 1: Write the failing test**

Create `ClaveTests/BIP39Tests.swift`:

```swift
import XCTest
@testable import Clave

final class BIP39Tests: XCTestCase {

    func testWordlistShape() {
        XCTAssertEqual(BIP39Wordlist.english.count, 2048)
        XCTAssertEqual(BIP39Wordlist.english.first, "abandon")
        XCTAssertEqual(BIP39Wordlist.english.last, "zoo")
        // Sorted ascending (BIP-39 reference property)
        XCTAssertEqual(BIP39Wordlist.english, BIP39Wordlist.english.sorted())
        // No duplicates
        XCTAssertEqual(Set(BIP39Wordlist.english).count, 2048)
    }

    /// Trezor BIP-39 test vector (16-byte entropy → 12 words).
    /// All-zero entropy is the canonical first vector.
    func testEntropyToMnemonic_allZero() throws {
        let entropy = Data(repeating: 0x00, count: 16)
        let mnemonic = try BIP39.mnemonic(from: entropy)
        XCTAssertEqual(
            mnemonic,
            "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        )
    }

    /// Trezor BIP-39 test vector (24-byte all-ones).
    func testEntropyToMnemonic_legalWinner() throws {
        let entropy = Data(repeating: 0x7f, count: 16)
        let mnemonic = try BIP39.mnemonic(from: entropy)
        XCTAssertEqual(
            mnemonic,
            "legal winner thank year wave sausage worth useful legal winner thank yellow"
        )
    }

    func testGenerate12_returnsValidMnemonic() throws {
        let m = try BIP39.generate(strength: .bits128)
        let words = m.split(separator: " ")
        XCTAssertEqual(words.count, 12)
        XCTAssertTrue(words.allSatisfy { BIP39Wordlist.english.contains(String($0)) })
    }

    func testRejectsBadEntropyLength() {
        XCTAssertThrowsError(try BIP39.mnemonic(from: Data(repeating: 0, count: 15)))
        XCTAssertThrowsError(try BIP39.mnemonic(from: Data(repeating: 0, count: 17)))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
xcodebuild test -project Clave.xcodeproj -scheme Clave \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:ClaveTests/BIP39Tests 2>&1 | tail -20
```

Expected: build FAILS with `cannot find 'BIP39Wordlist' in scope`.

- [ ] **Step 3: Add the wordlist file**

Create `Clave/Backup/BIP39Wordlist.swift` containing the canonical BIP-39 English wordlist as a `static let english: [String]`. Source: `https://github.com/bitcoin/bips/blob/master/bip-0039/english.txt` (2048 lines, alphabetical). Generate the Swift literal mechanically:

```bash
curl -sSL https://raw.githubusercontent.com/bitcoin/bips/master/bip-0039/english.txt \
  | awk 'BEGIN{print "enum BIP39Wordlist {\n    static let english: [String] = ["} \
         {printf "        \"%s\",\n", $0} \
         END{print "    ]\n}"}' \
  > Clave/Backup/BIP39Wordlist.swift
```

Verify the file starts with `"abandon"` and ends with `"zoo"`. The wordlist as a Swift array compiles into ~16 KB of binary — acceptable for the main-app target.

- [ ] **Step 4: Add the generator**

Create `Clave/Backup/BIP39.swift`:

```swift
import Foundation
import CryptoKit

/// BIP-39 entropy → words encoder. We only need this direction; mnemonic →
/// seed → keys is handled by rust-nostr's `Keys.fromMnemonic` in `NIP06`.
enum BIP39 {

    enum Strength {
        case bits128  // 16 bytes entropy → 12 words
        case bits256  // 32 bytes entropy → 24 words

        var entropyBytes: Int {
            switch self {
            case .bits128: return 16
            case .bits256: return 32
            }
        }
    }

    enum BIP39Error: Error {
        case invalidEntropyLength(Int)
    }

    /// Generate a fresh mnemonic using `SecRandomCopyBytes` for entropy.
    static func generate(strength: Strength = .bits128) throws -> String {
        var bytes = [UInt8](repeating: 0, count: strength.entropyBytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            // SecRandomCopyBytes failing is catastrophic; surface clearly.
            fatalError("SecRandomCopyBytes failed: \(status)")
        }
        return try mnemonic(from: Data(bytes))
    }

    /// Deterministic entropy → words conversion (BIP-39 §Generating the mnemonic).
    /// Entropy length must be a multiple of 4 bytes between 16 and 32 inclusive.
    static func mnemonic(from entropy: Data) throws -> String {
        guard [16, 20, 24, 28, 32].contains(entropy.count) else {
            throw BIP39Error.invalidEntropyLength(entropy.count)
        }
        // Checksum = first (entropyBits / 32) bits of SHA-256(entropy).
        let checksumBits = entropy.count / 4   // bytes → bits/32
        let hash = SHA256.hash(data: entropy)
        let checksumByte = hash.first!

        // Concatenate entropy bits + checksum bits, then chunk into 11-bit groups.
        var bits: [UInt8] = []
        bits.reserveCapacity(entropy.count * 8 + checksumBits)
        for byte in entropy {
            for i in (0..<8).reversed() {
                bits.append((byte >> i) & 1)
            }
        }
        for i in 0..<checksumBits {
            bits.append((checksumByte >> (7 - i)) & 1)
        }

        var words: [String] = []
        var idx = 0
        while idx + 11 <= bits.count {
            var groupValue: Int = 0
            for k in 0..<11 {
                groupValue = (groupValue << 1) | Int(bits[idx + k])
            }
            words.append(BIP39Wordlist.english[groupValue])
            idx += 11
        }
        return words.joined(separator: " ")
    }

    /// Validate that a user-typed mnemonic is shape-correct: 12/15/18/21/24 words,
    /// all in the wordlist. We deliberately do NOT validate the checksum here —
    /// rust-nostr's `Keys.fromMnemonic` does that as part of derivation, and a bad
    /// checksum surfaces there with a clearer "this is not a valid seed" error.
    static func isShapeValid(_ mnemonic: String) -> Bool {
        let words = mnemonic.split(separator: " ").map { String($0) }
        guard [12, 15, 18, 21, 24].contains(words.count) else { return false }
        let set = Set(BIP39Wordlist.english)
        return words.allSatisfy { set.contains($0) }
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

```
xcodebuild test -project Clave.xcodeproj -scheme Clave \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:ClaveTests/BIP39Tests 2>&1 | tail -20
```

Expected: 5 tests, all PASS.

- [ ] **Step 6: Commit**

```bash
git add Clave/Backup/BIP39Wordlist.swift Clave/Backup/BIP39.swift \
        ClaveTests/BIP39Tests.swift
git commit -m "$(cat <<'EOF'
feat(backup): BIP-39 wordlist + entropy→words generator

Hand-rolled BIP-39 (~30 lines + canonical English wordlist) per the
Tier 1 design spec — no third-party crypto dep, consistent with the
project's self-contained crypto style. We only need entropy → words;
words → seed → keys is rust-nostr's job via Keys.fromMnemonic.

Generator uses SecRandomCopyBytes for entropy and CryptoKit's SHA256
for the checksum. Trezor BIP-39 test vectors (all-zero and "legal
winner ... thank yellow") pin correctness. Shape-only validator for
user-typed mnemonics; checksum validation happens at derivation time.

https://claude.ai/code/session_011AATP4KC3JVkuBvLCtL5zx
EOF
)"
```

### Task 2: NIP-49 wrapper (`EncryptedSecretKey`)

**Files:**

- Create: `Clave/Backup/NIP49.swift`
- Test: `ClaveTests/NIP49WrapperTests.swift`

Thin Swift convenience around `nostr-sdk-swift`'s `EncryptedSecretKey`. Codifies Clave's `KeySecurity` policy and `logN` defaults so callers don't have to remember them.

- [ ] **Step 1: Write the failing test**

Create `ClaveTests/NIP49WrapperTests.swift`:

```swift
import XCTest
import NostrSDK
@testable import Clave

final class NIP49WrapperTests: XCTestCase {

    private let testNsec = "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"
    private let passphrase = "correct horse battery staple"

    func testRoundTrip_generatedKey() throws {
        let key = try SecretKey.parse(secretKey: testNsec)
        let blob = try NIP49.encrypt(secretKey: key,
                                     passphrase: passphrase,
                                     origin: .generatedInApp)
        XCTAssertTrue(blob.hasPrefix("ncryptsec1"))
        XCTAssertEqual(try NIP49.keySecurity(of: blob), .medium)

        let decrypted = try NIP49.decrypt(blob, passphrase: passphrase)
        XCTAssertEqual(try decrypted.toBech32(), testNsec)
    }

    func testRoundTrip_pasteImportedKey() throws {
        let key = try SecretKey.parse(secretKey: testNsec)
        let blob = try NIP49.encrypt(secretKey: key,
                                     passphrase: passphrase,
                                     origin: .pasteImported)
        XCTAssertEqual(try NIP49.keySecurity(of: blob), .unknown)
        XCTAssertEqual(try NIP49.decrypt(blob, passphrase: passphrase).toBech32(),
                       testNsec)
    }

    func testWrongPassphraseThrows() throws {
        let key = try SecretKey.parse(secretKey: testNsec)
        let blob = try NIP49.encrypt(secretKey: key,
                                     passphrase: passphrase,
                                     origin: .generatedInApp)
        XCTAssertThrowsError(try NIP49.decrypt(blob, passphrase: "wrong"))
    }

    func testPassphraseIsNFKCNormalized() throws {
        // U+00E9 (precomposed é) and U+0065 U+0301 (e + combining acute) must
        // produce the same key. NIP-49 requires NFKC normalization.
        let key = try SecretKey.parse(secretKey: testNsec)
        let blob = try NIP49.encrypt(secretKey: key,
                                     passphrase: "caf\u{00E9}",
                                     origin: .generatedInApp)
        let decrypted = try NIP49.decrypt(blob, passphrase: "cafe\u{0301}")
        XCTAssertEqual(try decrypted.toBech32(), testNsec)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: build FAILS — `NIP49` doesn't exist.

- [ ] **Step 3: Implement the wrapper**

Create `Clave/Backup/NIP49.swift`:

```swift
import Foundation
import NostrSDK

/// Thin convenience over rust-nostr's `EncryptedSecretKey`. Hides:
///   - the explicit `logN` / `KeySecurity` arguments so callers pick policy,
///     not raw values
///   - NFKC normalization of the passphrase (NIP-49 requirement)
///   - the bech32 round-trip
enum NIP49 {

    /// Where did this key come from? Drives the `KeySecurity` byte.
    /// `.generatedInApp` → `.medium` (we know the key never escaped the secure
    /// path). `.pasteImported` → `.unknown` (we can't attest to prior handling).
    enum Origin {
        case generatedInApp
        case pasteImported
    }

    /// Default scrypt cost. NIP-49 stores log_n in the blob so restores work
    /// regardless of the cost factor used at encryption time. 16 is ~1–2s on
    /// a modern iPhone — acceptable UX. Callers can override via `logN:`.
    static let defaultLogN: UInt8 = 16
    /// Optional "stronger / slower" upgrade in the passphrase UI.
    static let strongerLogN: UInt8 = 18

    enum NIP49Error: Error {
        case decryptFailed
    }

    /// Encrypt a `SecretKey` under `passphrase` and return the bech32 `ncryptsec1…`
    /// string. The passphrase is NFKC-normalized per NIP-49 before being passed to
    /// the SDK.
    static func encrypt(secretKey: SecretKey,
                        passphrase: String,
                        origin: Origin,
                        logN: UInt8 = defaultLogN) throws -> String {
        let normalized = passphrase.precomposedStringWithCompatibilityMapping
        let security: KeySecurity = (origin == .generatedInApp) ? .medium : .unknown
        let encrypted = try EncryptedSecretKey(secretKey: secretKey,
                                               password: normalized,
                                               logN: logN,
                                               keySecurity: security)
        return try encrypted.toBech32()
    }

    /// Decrypt an `ncryptsec1…` string into a `SecretKey`. Throws on bad
    /// passphrase / malformed input.
    static func decrypt(_ ncryptsec: String, passphrase: String) throws -> SecretKey {
        let normalized = passphrase.precomposedStringWithCompatibilityMapping
        let encrypted = try EncryptedSecretKey.fromBech32(ncryptsec)
        do {
            return try encrypted.decrypt(password: normalized)
        } catch {
            throw NIP49Error.decryptFailed
        }
    }

    /// Inspect the `KeySecurity` byte of an existing ncryptsec — used to label
    /// imported encrypted backups in the UI ("This backup is from a key that
    /// was handled securely / unknown / weakly").
    static func keySecurity(of ncryptsec: String) throws -> KeySecurity {
        let encrypted = try EncryptedSecretKey.fromBech32(ncryptsec)
        return encrypted.keySecurity()
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Expected: 4 tests PASS. If `EncryptedSecretKey.init(secretKey:password:logN:keySecurity:)` has a different argument label than the verified design (Swift UniFFI names can drift between versions), fix the call site to match what the build error reports — the surface is small.

- [ ] **Step 5: Commit**

```bash
git add Clave/Backup/NIP49.swift ClaveTests/NIP49WrapperTests.swift
git commit -m "$(cat <<'EOF'
feat(backup): NIP-49 wrapper with KeySecurity policy

Thin convenience over rust-nostr's EncryptedSecretKey:
- NFKC-normalize the passphrase (NIP-49 requirement)
- Encode Clave's KeySecurity policy via an Origin enum:
  generatedInApp → .medium; pasteImported → .unknown
- Default logN=16 (~1–2s on a modern iPhone); strongerLogN=18 exposed
  for an opt-in "stronger / slower" toggle in the passphrase UI
- Round-trip + wrong-passphrase + NFKC tests pin correctness

https://claude.ai/code/session_011AATP4KC3JVkuBvLCtL5zx
EOF
)"
```

### Task 3: NIP-06 wrapper (`Keys.fromMnemonic`)

**Files:**

- Create: `Clave/Backup/NIP06.swift`
- Test: `ClaveTests/NIP06WrapperTests.swift`

- [ ] **Step 1: Write the failing test**

Use a known NIP-06 test vector. From the NIP-06 spec, mnemonic "leader monkey parrot ring guide accident before fence cannon height naive bean" with no passphrase, account 0, derives an nsec that starts with a known prefix — but the most stable assertion is "derives a deterministic, non-empty key matching a value we record":

```swift
import XCTest
import NostrSDK
@testable import Clave

final class NIP06WrapperTests: XCTestCase {

    func testDeriveFromKnownMnemonic() throws {
        // NIP-06 reference vector
        let mnemonic = "leader monkey parrot ring guide accident before fence cannon height naive bean"
        let keys = try NIP06.deriveKeys(mnemonic: mnemonic, passphrase: nil, account: 0)
        // The exact npub for account=0 of this mnemonic is deterministic.
        // Capture once from a verified independent NIP-06 implementation
        // (rust-nostr CLI, or nostr-tools.nip06.privateKeyFromSeedWords) and
        // pin it here. Placeholder shown for the plan; fill at test-write time.
        XCTAssertEqual(try keys.publicKey().toBech32(),
                       "<paste exact npub captured from a reference impl>")
    }

    func testGenerateThenDerive_isDeterministic() throws {
        let m = try BIP39.generate(strength: .bits128)
        let a = try NIP06.deriveKeys(mnemonic: m, passphrase: nil, account: 0)
        let b = try NIP06.deriveKeys(mnemonic: m, passphrase: nil, account: 0)
        XCTAssertEqual(try a.publicKey().toBech32(), try b.publicKey().toBech32())
    }

    func testDifferentAccountsDeriveDifferentKeys() throws {
        let m = try BIP39.generate(strength: .bits128)
        let a = try NIP06.deriveKeys(mnemonic: m, passphrase: nil, account: 0)
        let b = try NIP06.deriveKeys(mnemonic: m, passphrase: nil, account: 1)
        XCTAssertNotEqual(try a.publicKey().toBech32(),
                          try b.publicKey().toBech32())
    }
}
```

Capture the expected npub once via a reference NIP-06 implementation (rust-nostr CLI: `nostr-cli keys from-mnemonic "..."`) and paste into the test. This pins us to the spec-correct derivation forever.

- [ ] **Step 2: Run test to verify it fails**

Expected: build FAILS — `NIP06` missing.

- [ ] **Step 3: Implement the wrapper**

Create `Clave/Backup/NIP06.swift`:

```swift
import Foundation
import NostrSDK

/// Thin wrapper over `Keys.fromMnemonic`. We pin `typ = 0` and `index = 0`
/// (the trailing `/0/0` of `m/44'/1237'/account'/0/0`) so callers only choose
/// the account index, which is the only parameter NIP-06 says clients vary.
enum NIP06 {

    /// Derive Nostr `Keys` at `m/44'/1237'/account'/0/0`. Pass `nil` passphrase
    /// for the standard "no BIP-39 passphrase" case — clave does not use the
    /// BIP-39 passphrase feature because it conflates with the NIP-49 backup
    /// passphrase in user mental models.
    static func deriveKeys(mnemonic: String,
                           passphrase: String? = nil,
                           account: UInt32 = 0) throws -> Keys {
        return try Keys.fromMnemonic(mnemonic: mnemonic,
                                     passphrase: passphrase,
                                     account: account,
                                     typ: 0,
                                     index: 0)
    }
}
```

If the Swift UniFFI signature differs (e.g. `accountIndex:` rather than `account:`), adjust to match. The test catches it.

- [ ] **Step 4: Run the test to verify it passes**

Expected: 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Clave/Backup/NIP06.swift ClaveTests/NIP06WrapperTests.swift
git commit -m "$(cat <<'EOF'
feat(backup): NIP-06 wrapper (Keys.fromMnemonic at m/44'/1237'/N'/0/0)

Pins typ=0 / index=0 — callers only vary the account index, which is
the single parameter NIP-06 says clients vary. No BIP-39 passphrase
exposed; we don't use it (it would conflate with the NIP-49 backup
passphrase in user mental models).

Test pins derivation against a known reference vector (npub captured
from rust-nostr CLI) so we never silently regress the derivation path.

https://claude.ai/code/session_011AATP4KC3JVkuBvLCtL5zx
EOF
)"
```

### Task 4: `MnemonicStorage` — biometric-gated Keychain

**Files:**

- Modify: `Shared/SharedConstants.swift` (add `keychainServiceMnemonic`)
- Create: `Clave/Backup/MnemonicStorage.swift`
- Test: `ClaveTests/MnemonicStorageTests.swift`

The mnemonic lives in a SEPARATE Keychain entry from the working key, gated by `SecAccessControl` requiring biometric (`.biometryAny`, fallback to passcode). NSE never touches it. "Show seed words later" → biometric prompt → reveal.

> **Why biometric-gated and not passphrase-encrypted?** Apple's Secure Enclave handles the encryption; access policy is enforced by iOS. This avoids needing a second user-passphrase (the NIP-49 passphrase is reserved for off-device export). UX is cleaner: one passphrase for export, biometric for "show me my words."

- [ ] **Step 1: Add the service constant**

Edit `Shared/SharedConstants.swift`, add:

```swift
    /// Keychain service used for biometric-gated mnemonic storage. Distinct
    /// from `keychainService` (working keys) so the access-control attributes
    /// don't bleed across rows.
    static let keychainServiceMnemonic = "dev.nostr.clave.mnemonic"
```

- [ ] **Step 2: Write the failing test**

Create `ClaveTests/MnemonicStorageTests.swift`:

```swift
import XCTest
@testable import Clave

/// MnemonicStorage requires biometric evaluation on a real device. These tests
/// cover the shape of the API (save / delete / contains) without exercising
/// the biometric path; the read path is verified manually in the smoke test
/// at the end of Phase 1.
final class MnemonicStorageTests: XCTestCase {

    private let pk = "abc123" + String(repeating: "0", count: 58)  // 64 hex chars
    private let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    override func setUp() {
        MnemonicStorage.delete(for: pk)
    }

    func testContainsAfterSave() throws {
        try MnemonicStorage.save(mnemonic: mnemonic, for: pk)
        XCTAssertTrue(MnemonicStorage.contains(for: pk))
    }

    func testDeleteRemoves() throws {
        try MnemonicStorage.save(mnemonic: mnemonic, for: pk)
        MnemonicStorage.delete(for: pk)
        XCTAssertFalse(MnemonicStorage.contains(for: pk))
    }

    func testSaveTwiceReplaces() throws {
        try MnemonicStorage.save(mnemonic: mnemonic, for: pk)
        try MnemonicStorage.save(mnemonic: "new words " + mnemonic, for: pk)
        XCTAssertTrue(MnemonicStorage.contains(for: pk))
    }
}
```

- [ ] **Step 3: Implement**

Create `Clave/Backup/MnemonicStorage.swift`:

```swift
import Foundation
import Security
import LocalAuthentication

/// Per-pubkey biometric-gated mnemonic storage. The mnemonic plaintext lives
/// in iOS Keychain with SecAccessControl requiring biometric evaluation; the
/// Secure Enclave handles the at-rest encryption. NSE never reads this entry
/// — backup/restore is a main-app concern only.
enum MnemonicStorage {

    enum MnemonicStorageError: Error {
        case writeFailed(OSStatus)
        case readFailed(OSStatus)
        case accessControlCreationFailed
    }

    /// True if a mnemonic entry exists for `pubkeyHex`. Does NOT trigger a
    /// biometric prompt — uses `kSecUseAuthenticationUI = .skip` for the check.
    static func contains(for pubkeyHex: String) -> Bool {
        var query = baseQuery(for: pubkeyHex)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    /// Save (or replace) the mnemonic for `pubkeyHex`. Biometric is NOT required
    /// to WRITE — only to read. This lets onboarding save without an extra prompt
    /// immediately after generation.
    static func save(mnemonic: String, for pubkeyHex: String) throws {
        delete(for: pubkeyHex)

        guard let data = mnemonic.data(using: .utf8) else {
            throw MnemonicStorageError.writeFailed(errSecParam)
        }

        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.biometryAny, .or, .devicePasscode],
            &error
        ) else {
            throw MnemonicStorageError.accessControlCreationFailed
        }

        var query = baseQuery(for: pubkeyHex)
        query[kSecValueData as String] = data
        query[kSecAttrAccessControl as String] = access

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MnemonicStorageError.writeFailed(status)
        }
    }

    /// Read the mnemonic. **This triggers a biometric/passcode prompt.** Returns
    /// nil if the user cancels or no entry exists. Caller MUST handle nil as
    /// "the user did not authorize" and surface a retry-able UI.
    static func read(for pubkeyHex: String, reason: String) -> String? {
        var query = baseQuery(for: pubkeyHex)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let context = LAContext()
        context.localizedReason = reason
        query[kSecUseAuthenticationContext as String] = context

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let s = String(data: data, encoding: .utf8) else {
            return nil
        }
        return s
    }

    /// No biometric required — also used during account deletion.
    static func delete(for pubkeyHex: String) {
        let query = baseQuery(for: pubkeyHex)
        SecItemDelete(query as CFDictionary)
    }

    private static func baseQuery(for pubkeyHex: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConstants.keychainServiceMnemonic,
            kSecAttrAccount as String: pubkeyHex
        ]
    }
}
```

- [ ] **Step 4: Run the tests**

Note: the `contains` test passes on simulator; the `read` path requires a real device with biometrics enrolled — covered in the Phase 1 smoke test, not unit-tested.

Expected: 3 tests PASS on simulator.

- [ ] **Step 5: Commit**

```bash
git add Shared/SharedConstants.swift Clave/Backup/MnemonicStorage.swift \
        ClaveTests/MnemonicStorageTests.swift
git commit -m "$(cat <<'EOF'
feat(backup): biometric-gated MnemonicStorage (per-pubkey Keychain)

Mnemonic plaintext lives in iOS Keychain under a separate service
(dev.nostr.clave.mnemonic), keyed by pubkey hex. SecAccessControl
requires biometry-or-passcode for READ; WRITE is unrestricted so
onboarding can save without an extra prompt immediately after key
generation.

NSE never reads this entry — backup is a main-app concern only. The
working-key Keychain entry (SharedKeychain.swift) is unchanged: NSE
still wakes on push and signs from ThisDeviceOnly storage as today.

Unit tests cover the API shape (contains/save/delete) on simulator;
the biometric-gated read path is verified in the Phase 1 smoke test
on a real device.

https://claude.ai/code/session_011AATP4KC3JVkuBvLCtL5zx
EOF
)"
```

### Task 5: `BackupStatus` model + per-account persistence

**Files:**

- Create: `Clave/Models/BackupStatus.swift`
- Modify: `Shared/SharedStorage.swift`
- Test: `ClaveTests/BackupStatusTests.swift`

Per-account state surfaced in UI: not-backed-up / confirmed / skipped. Stored in `SharedStorage` (App Group UserDefaults, same pattern as `ConnectedClient` rows), keyed by signer pubkey hex.

- [ ] **Step 1: Write the failing test**

Create `ClaveTests/BackupStatusTests.swift`:

```swift
import XCTest
@testable import Clave

final class BackupStatusTests: XCTestCase {

    private let pk = "abc" + String(repeating: "0", count: 61)

    override func setUp() {
        SharedStorage.setBackupStatus(.notBackedUp, for: pk)
    }

    func testDefaultsToNotBackedUp() {
        XCTAssertEqual(SharedStorage.getBackupStatus(for: "unknown-pk"), .notBackedUp)
    }

    func testRoundTripConfirmed() {
        SharedStorage.setBackupStatus(.confirmed, for: pk)
        XCTAssertEqual(SharedStorage.getBackupStatus(for: pk), .confirmed)
    }

    func testRoundTripSkipped() {
        SharedStorage.setBackupStatus(.skipped, for: pk)
        XCTAssertEqual(SharedStorage.getBackupStatus(for: pk), .skipped)
    }

    func testCodableRawValues() {
        // Raw values are stable on-disk identifiers; changing them would
        // silently reset all users' backup status. Pin them here.
        XCTAssertEqual(BackupStatus.notBackedUp.rawValue, "notBackedUp")
        XCTAssertEqual(BackupStatus.confirmed.rawValue, "confirmed")
        XCTAssertEqual(BackupStatus.skipped.rawValue, "skipped")
    }
}
```

- [ ] **Step 2: Implement the model**

Create `Clave/Models/BackupStatus.swift`:

```swift
import Foundation

/// Per-account backup state surfaced in the UI.
///   - `.notBackedUp` — default; the user hasn't completed the onboarding
///     backup-confirm step nor exported the key.
///   - `.confirmed` — user completed onboarding write-down + verify, OR
///     successfully exported an ncryptsec / completed iCloud opt-in.
///   - `.skipped` — user explicitly dismissed the onboarding backup prompt.
///     Distinct from `.notBackedUp` so we can soften the "back up now" nudge
///     and avoid pestering. Treated identically for safety messaging.
enum BackupStatus: String, Codable {
    case notBackedUp
    case confirmed
    case skipped
}
```

- [ ] **Step 3: Add persistence helpers to `SharedStorage`**

In `Shared/SharedStorage.swift`, add:

```swift
    // MARK: - Backup status (per-account, Tier 1)

    private static func backupStatusKey(for pubkeyHex: String) -> String {
        return "backupStatus.\(pubkeyHex)"
    }

    static func getBackupStatus(for pubkeyHex: String) -> BackupStatus {
        let raw = sharedDefaults.string(forKey: backupStatusKey(for: pubkeyHex))
        return raw.flatMap { BackupStatus(rawValue: $0) } ?? .notBackedUp
    }

    static func setBackupStatus(_ status: BackupStatus, for pubkeyHex: String) {
        sharedDefaults.set(status.rawValue, forKey: backupStatusKey(for: pubkeyHex))
    }
```

Note: `BackupStatus` is referenced from `Shared/SharedStorage.swift` but defined under `Clave/Models/`. Since `SharedStorage.swift` is in the `Shared/` group (compiled into the NSE too), and `BackupStatus` is main-app-only, this creates a target-membership conflict. Resolution: **move `BackupStatus.swift` into the `Shared/` group** (define alongside other `SharedModels.swift` types). Update the Create entry above accordingly and put the enum in `Shared/SharedModels.swift` (or a new `Shared/BackupStatus.swift`).

- [ ] **Step 4: Run the tests**

Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Shared/BackupStatus.swift Shared/SharedStorage.swift \
        ClaveTests/BackupStatusTests.swift
git commit -m "$(cat <<'EOF'
feat(backup): BackupStatus model + per-account persistence

Three-state enum (notBackedUp / confirmed / skipped) tracked per
pubkey hex in SharedStorage (App Group UserDefaults). .skipped is
distinct from .notBackedUp so we can soften repeat nudges, but both
trigger the safety messaging.

Lives in Shared/ (alongside SharedModels) because SharedStorage —
which compiles into both main app and NSE — references it; consumers
in UI are main-app only.

Raw values pinned by test (changing them would silently reset every
user's backup status).

https://claude.ai/code/session_011AATP4KC3JVkuBvLCtL5zx
EOF
)"
```

### Task 6: Refactor `AccountManager.create()` to mnemonic-based generation

**Files:**

- Modify: `Clave/AppState+AccountManager.swift`
- Test: `ClaveTests/AccountManagerImportTests.swift` (will grow across Tasks 6–8)

Existing `create()` calls `Keys.generate()` (raw entropy). The new path: BIP-39 mnemonic → derive via NIP-06 → store working key in Keychain (as today) + store mnemonic in `MnemonicStorage` (biometric-gated). Existing keys / paste-imported keys are unaffected.

- [ ] **Step 1: Write the failing test**

Create `ClaveTests/AccountManagerImportTests.swift`:

```swift
import XCTest
import NostrSDK
@testable import Clave

final class AccountManagerImportTests: XCTestCase {

    @MainActor
    func testCreate_returnsAccountWithStoredMnemonic() async throws {
        let appState = AppState()
        let account = try appState.createAccount(label: "Test")
        defer { appState.deleteAccount(pubkey: account.pubkeyHex) }

        // Working key exists in the regular Keychain (unchanged path).
        XCTAssertNotNil(SharedKeychain.loadNsec(for: account.pubkeyHex))

        // Mnemonic exists in the biometric-gated Keychain.
        XCTAssertTrue(MnemonicStorage.contains(for: account.pubkeyHex))
    }

    @MainActor
    func testCreate_keyDerivesFromStoredMnemonic() async throws {
        // The working key in Keychain must equal the key derived from the
        // stored mnemonic at NIP-06 account=0. Otherwise restore-from-seed
        // would silently produce a different identity.
        // This test reads the mnemonic via a test-only hook that bypasses
        // biometric — see `MnemonicStorage.readForTesting(...)` added in
        // the test target only via #if DEBUG.
        // ... (see Step 3 for the DEBUG hook)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: build FAILS or first test fails — `MnemonicStorage.contains` returns false because `create()` doesn't save a mnemonic yet.

- [ ] **Step 3: Refactor `create()`**

In `Clave/AppState+AccountManager.swift`, change `create()` (current line ~197 uses `Keys.generate()`):

```swift
    /// Create a new account using NIP-06 mnemonic-backed generation. The
    /// mnemonic is the user's seed-phrase backup; the working key (derived
    /// at m/44'/1237'/0'/0/0) is stored in the Keychain exactly as today.
    @discardableResult
    func createAccount(label: String? = nil) throws -> Account {
        // 1. Generate 16 bytes of entropy → 12-word BIP-39 mnemonic.
        let mnemonic = try BIP39.generate(strength: .bits128)
        // 2. Derive Keys via NIP-06 at account=0.
        let keys = try NIP06.deriveKeys(mnemonic: mnemonic, passphrase: nil, account: 0)
        let pubkeyHex = try keys.publicKey().toHex()
        let nsec = try keys.secretKey().toBech32()

        // 3. Store working key in the regular Keychain (unchanged path).
        try SharedKeychain.saveNsec(nsec, for: pubkeyHex)

        // 4. Store the mnemonic in the biometric-gated Keychain.
        try MnemonicStorage.save(mnemonic: mnemonic, for: pubkeyHex)

        // 5. Build the Account model + persist via existing flow.
        let account = Account(pubkeyHex: pubkeyHex,
                              displayLabel: label ?? Self.defaultLabel(),
                              createdAt: Date().timeIntervalSince1970)
        accounts.append(account)
        persistAccounts()
        SharedConstants.sharedDefaults.set(pubkeyHex,
                                           forKey: SharedConstants.currentSignerPubkeyHexKey)
        // 6. Initial backup status — onboarding will flip to .confirmed.
        SharedStorage.setBackupStatus(.notBackedUp, for: pubkeyHex)
        return account
    }
```

Add a `#if DEBUG`-gated hook in `MnemonicStorage` for the derive-from-mnemonic test (bypasses biometric so unit tests can verify the derivation invariant):

```swift
#if DEBUG
    /// Test-only: read without prompting. Available only in DEBUG builds.
    static func readForTesting(for pubkeyHex: String) -> String? {
        var query = baseQuery(for: pubkeyHex)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let d = result as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
#endif
```

Fill in the `testCreate_keyDerivesFromStoredMnemonic` test body using `MnemonicStorage.readForTesting(...)` → `NIP06.deriveKeys(...)` → compare pubkey to the stored Keychain key's pubkey.

- [ ] **Step 4: Run the tests**

Expected: 2 tests PASS.

- [ ] **Step 5: Smoke-check the existing AccountManager tests**

Run the full `ClaveTests/AccountManager*` suite to confirm no regressions in existing import/delete paths. Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add Clave/AppState+AccountManager.swift Clave/Backup/MnemonicStorage.swift \
        ClaveTests/AccountManagerImportTests.swift
git commit -m "$(cat <<'EOF'
feat(backup): mnemonic-backed key generation (NIP-06)

createAccount() now generates a 12-word BIP-39 mnemonic and derives
the working key at NIP-06 path m/44'/1237'/0'/0/0 (account=0). The
working key is stored in the regular Keychain exactly as today — NSE
behavior is unchanged. The mnemonic is stored in the biometric-gated
MnemonicStorage so the user can later view their seed words after a
Face ID prompt.

initial BackupStatus is .notBackedUp; onboarding will flip it to
.confirmed after the write-down + verify-3-words step (Task 14).

The derive-from-mnemonic invariant (Keychain key == NIP-06 derive of
stored mnemonic) is locked in by a unit test that uses a DEBUG-only
biometric-bypass read on MnemonicStorage — silently regressing the
derivation would break restore-from-seed for every new account.

https://claude.ai/code/session_011AATP4KC3JVkuBvLCtL5zx
EOF
)"
```

### Task 7: Add `importMnemonic(words:)`

**Files:**

- Modify: `Clave/AppState+AccountManager.swift`
- Test: `ClaveTests/AccountManagerImportTests.swift` (extend)

Mirror of `create()` but uses user-supplied words. Lets users restore from a seed phrase backup.

- [ ] **Step 1: Write the failing test**

Append to `ClaveTests/AccountManagerImportTests.swift`:

```swift
    @MainActor
    func testImportMnemonic_derivesExpectedPubkey() async throws {
        let appState = AppState()
        let mnemonic = "leader monkey parrot ring guide accident before fence cannon height naive bean"
        let account = try appState.importMnemonic(words: mnemonic, label: "Restored")
        defer { appState.deleteAccount(pubkey: account.pubkeyHex) }

        // Same NIP-06 derivation → same pubkey as Task 3's test vector.
        XCTAssertEqual(account.pubkeyHex,
                       "<paste hex pubkey of NIP-06 reference vector>")
        XCTAssertTrue(MnemonicStorage.contains(for: account.pubkeyHex))
    }

    @MainActor
    func testImportMnemonic_rejectsInvalidShape() async {
        let appState = AppState()
        do {
            _ = try appState.importMnemonic(words: "not a valid mnemonic", label: nil)
            XCTFail("Expected throw for invalid mnemonic shape")
        } catch {
            // expected
        }
    }
```

- [ ] **Step 2: Implement**

In `AppState+AccountManager.swift`:

```swift
    /// Restore an account from a user-supplied BIP-39 mnemonic. Same derivation
    /// path as `createAccount` so a generated → backed-up → restored cycle is
    /// idempotent.
    @discardableResult
    func importMnemonic(words: String, label: String? = nil) throws -> Account {
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard BIP39.isShapeValid(trimmed) else {
            throw AccountError.invalidMnemonic
        }
        let keys = try NIP06.deriveKeys(mnemonic: trimmed, passphrase: nil, account: 0)
        let pubkeyHex = try keys.publicKey().toHex()

        if accounts.contains(where: { $0.pubkeyHex == pubkeyHex }) {
            throw AccountError.duplicateAccount
        }
        let nsec = try keys.secretKey().toBech32()
        try SharedKeychain.saveNsec(nsec, for: pubkeyHex)
        try MnemonicStorage.save(mnemonic: trimmed, for: pubkeyHex)

        let account = Account(pubkeyHex: pubkeyHex,
                              displayLabel: label ?? Self.defaultLabel(),
                              createdAt: Date().timeIntervalSince1970)
        accounts.append(account)
        persistAccounts()
        SharedConstants.sharedDefaults.set(pubkeyHex,
                                           forKey: SharedConstants.currentSignerPubkeyHexKey)
        // The user has the words by definition — count this as confirmed.
        SharedStorage.setBackupStatus(.confirmed, for: pubkeyHex)
        return account
    }
```

Add `case invalidMnemonic` / `case duplicateAccount` to `AccountError`.

- [ ] **Step 3: Run tests; commit**

```bash
git add Clave/AppState+AccountManager.swift ClaveTests/AccountManagerImportTests.swift
git commit -m "$(cat <<'EOF'
feat(backup): importMnemonic — restore from BIP-39 seed words

Mirror of createAccount but uses user-supplied words. Same NIP-06
derivation path so generated → backed up → restored cycles to the
exact same identity. Trims and lowercases; rejects invalid shape
(wrong word count or unknown word) at the boundary. BIP-39 checksum
is validated inside Keys.fromMnemonic — a checksum failure surfaces
with a clear error.

Imported-via-words accounts start with BackupStatus.confirmed (the
user has the words by definition).

https://claude.ai/code/session_011AATP4KC3JVkuBvLCtL5zx
EOF
)"
```

### Task 8: Add `importEncryptedKey(ncryptsec:passphrase:)`

**Files:**

- Modify: `Clave/AppState+AccountManager.swift`
- Test: `ClaveTests/AccountManagerImportTests.swift` (extend)

Decrypt an `ncryptsec` via the NIP-49 wrapper, store the working key. **No mnemonic** is stored — the user imported a key, not a seed phrase.

- [ ] **Step 1: Write the failing test**

```swift
    @MainActor
    func testImportEncryptedKey_roundTripWithOwnExport() async throws {
        // Generate, export to ncryptsec, delete, re-import — must match.
        let appState = AppState()
        let created = try appState.createAccount(label: nil)
        let originalPk = created.pubkeyHex
        guard let nsec = SharedKeychain.loadNsec(for: originalPk) else {
            return XCTFail("missing nsec")
        }
        let secretKey = try SecretKey.parse(secretKey: nsec)
        let ncryptsec = try NIP49.encrypt(secretKey: secretKey,
                                          passphrase: "pw",
                                          origin: .generatedInApp)
        appState.deleteAccount(pubkey: originalPk)

        let restored = try appState.importEncryptedKey(ncryptsec: ncryptsec,
                                                      passphrase: "pw",
                                                      label: nil)
        defer { appState.deleteAccount(pubkey: restored.pubkeyHex) }
        XCTAssertEqual(restored.pubkeyHex, originalPk)
        // No mnemonic stored — the user imported a key, not seed words.
        XCTAssertFalse(MnemonicStorage.contains(for: restored.pubkeyHex))
    }

    @MainActor
    func testImportEncryptedKey_wrongPassphrase() async {
        let appState = AppState()
        // ... encrypt with "pw", attempt decrypt with "wrong" — expect throw
    }
```

- [ ] **Step 2: Implement**

```swift
    @discardableResult
    func importEncryptedKey(ncryptsec: String,
                            passphrase: String,
                            label: String? = nil) throws -> Account {
        let secretKey = try NIP49.decrypt(ncryptsec, passphrase: passphrase)
        let pubkeyHex = try PublicKey.fromSecretKey(secretKey).toHex()
        if accounts.contains(where: { $0.pubkeyHex == pubkeyHex }) {
            throw AccountError.duplicateAccount
        }
        let nsec = try secretKey.toBech32()
        try SharedKeychain.saveNsec(nsec, for: pubkeyHex)
        // NO mnemonic — user imported a key, not a seed phrase.
        let account = Account(pubkeyHex: pubkeyHex,
                              displayLabel: label ?? Self.defaultLabel(),
                              createdAt: Date().timeIntervalSince1970)
        accounts.append(account)
        persistAccounts()
        SharedConstants.sharedDefaults.set(pubkeyHex,
                                           forKey: SharedConstants.currentSignerPubkeyHexKey)
        SharedStorage.setBackupStatus(.confirmed, for: pubkeyHex)  // they have the ncryptsec
        return account
    }
```

- [ ] **Step 3: Run tests; commit**

```bash
git commit -m "$(cat <<'EOF'
feat(backup): importEncryptedKey — restore from ncryptsec + passphrase

Decrypt an ncryptsec via NIP49.decrypt, derive pubkey, store the
working nsec in the Keychain exactly like paste-imported keys today.
No mnemonic is stored — the user provided a key, not seed words; "show
seed words" will be unavailable for this account (correct per spec —
legacy/imported keys have no associated mnemonic).

Status .confirmed on success (they have the ncryptsec).

Round-trip test: generate → export to ncryptsec → delete → import
matches the original pubkey. Wrong-passphrase test pins the error
path.

https://claude.ai/code/session_011AATP4KC3JVkuBvLCtL5zx
EOF
)"
```

### Task 9: `PassphraseEntry` reusable component

**Files:**

- Create: `Clave/Views/Backup/PassphraseEntry.swift`

Entry + confirm + strength meter + optional `logN` "stronger / slower" toggle. Used by `EncryptedBackupView`, `EncryptedBackupImportView`, and (Phase 2) the iCloud opt-in flow.

- [ ] **Step 1: Implement**

```swift
import SwiftUI

struct PassphraseEntry: View {
    @Binding var passphrase: String
    @Binding var confirmPassphrase: String
    @Binding var useStrongerScrypt: Bool

    let mode: Mode
    enum Mode { case create, decrypt }  // decrypt mode hides confirm + strength

    var isValid: Bool {
        switch mode {
        case .decrypt: return !passphrase.isEmpty
        case .create:
            return passphrase.count >= 12 && passphrase == confirmPassphrase
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SecureField("Passphrase", text: $passphrase)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(mode == .create ? .newPassword : .password)
                .submitLabel(.next)

            if mode == .create {
                SecureField("Confirm passphrase", text: $confirmPassphrase)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.newPassword)
                    .submitLabel(.go)

                StrengthMeter(passphrase: passphrase)

                Toggle("Stronger (slower) — higher scrypt cost",
                       isOn: $useStrongerScrypt)
                    .font(.subheadline)
                Text("Stronger backups take a few seconds longer to unlock. The cost factor is stored in the backup, so any device can restore.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct StrengthMeter: View {
    let passphrase: String
    var body: some View {
        let score = max(0, min(4, classify(passphrase)))
        let label = ["Too short", "Weak", "Okay", "Strong", "Very strong"][score]
        let color: Color = [.gray, .red, .orange, .yellow, .green][score]
        HStack(spacing: 4) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i < score ? color : Color(.systemGray5))
                    .frame(height: 4)
            }
        }
        Text(label).font(.caption2).foregroundStyle(.secondary)
    }
    private func classify(_ s: String) -> Int {
        var score = 0
        if s.count >= 12 { score += 1 }
        if s.count >= 16 { score += 1 }
        if s.rangeOfCharacter(from: .decimalDigits) != nil { score += 1 }
        if s.rangeOfCharacter(from: .punctuationCharacters) != nil { score += 1 }
        return score
    }
}
```

Heuristic strength meter — not zxcvbn-level, but visibly flags short/no-class passphrases. Plan a follow-up if user testing shows it's misleading.

- [ ] **Step 2: Commit**

```bash
git add Clave/Views/Backup/PassphraseEntry.swift
git commit -m "$(cat <<'EOF'
feat(backup): PassphraseEntry reusable component

Entry + confirm + heuristic strength meter + logN "stronger / slower"
toggle. Used by encrypted-export, encrypted-import, and (Phase 2)
iCloud opt-in flows.

The strength meter is a coarse 4-bar heuristic (length + char classes)
— not zxcvbn-level. Good enough to flag obviously-weak passphrases;
follow-up if user testing shows it's misleading.

https://claude.ai/code/session_011AATP4KC3JVkuBvLCtL5zx
EOF
)"
```

### Task 10: Refactor `ExportKeySheet` → three-option backup hub + `EncryptedBackupView` + QR

**Files:**

- Modify: `Clave/Views/Settings/ExportKeySheet.swift` (full refactor)
- Create: `Clave/Views/Backup/EncryptedBackupView.swift`

Today's `ExportKeySheet` does one thing: reveal nsec after biometric. Refactor to a hub with three options:

1. **Encrypted backup (`ncryptsec`)** — recommended; passphrase entry → encrypt → show string + Copy + QR
2. **Seed words** — biometric → reveal 12 words (disabled if `MnemonicStorage.contains(for:)` is false, with explanatory text)
3. **Secret key (`nsec`)** — demoted, behind extra "I understand the risk" confirmation, retains today's reveal UI

- [ ] **Step 1: Refactor `ExportKeySheet`**

```swift
import SwiftUI

struct ExportKeySheet: View {
    let pubkeyHex: String
    @Environment(\.dismiss) private var dismiss
    @State private var route: Route?

    enum Route: Hashable {
        case encrypted, seedWords, rawNsec
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { route = .encrypted } label: {
                        OptionRow(icon: "lock.shield.fill",
                                  title: "Encrypted backup",
                                  subtitle: "Recommended — passphrase-protected ncryptsec, safe to save anywhere.",
                                  tint: .green)
                    }
                }
                Section {
                    Button { route = .seedWords } label: {
                        OptionRow(icon: "doc.text.fill",
                                  title: "Seed words",
                                  subtitle: hasMnemonic
                                    ? "12 words. Write them down and store offline."
                                    : "Not available for this account (no seed phrase associated).",
                                  tint: hasMnemonic ? .blue : .gray)
                    }
                    .disabled(!hasMnemonic)
                }
                Section {
                    Button { route = .rawNsec } label: {
                        OptionRow(icon: "exclamationmark.triangle.fill",
                                  title: "Secret key (nsec)",
                                  subtitle: "Raw, unencrypted. Use only if you understand the risk.",
                                  tint: .orange)
                    }
                }
            }
            .navigationTitle("Back up account")
            .navigationDestination(item: $route) { route in
                switch route {
                case .encrypted:  EncryptedBackupView(pubkeyHex: pubkeyHex)
                case .seedWords:  SeedWordsView(pubkeyHex: pubkeyHex)
                case .rawNsec:    RawNsecRevealView(pubkeyHex: pubkeyHex)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .snapshotProtected()
    }

    private var hasMnemonic: Bool { MnemonicStorage.contains(for: pubkeyHex) }
}

private struct OptionRow: View { /* avatar/title/subtitle row, ~20 lines */ }
```

- [ ] **Step 2: Implement `EncryptedBackupView`**

Create `Clave/Views/Backup/EncryptedBackupView.swift`:

```swift
import SwiftUI

struct EncryptedBackupView: View {
    let pubkeyHex: String
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var useStronger = false
    @State private var result: String?  // ncryptsec
    @State private var encrypting = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let result {
                    resultView(ncryptsec: result)
                } else {
                    Text("Choose a passphrase. You'll need it (along with the backup string) to restore.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    PassphraseEntry(passphrase: $passphrase,
                                    confirmPassphrase: $confirm,
                                    useStrongerScrypt: $useStronger,
                                    mode: .create)
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    Button {
                        encrypt()
                    } label: {
                        if encrypting { ProgressView() }
                        else { Text("Create encrypted backup").frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(passphrase != confirm || passphrase.count < 12 || encrypting)

                    Text("If you forget this passphrase, this backup cannot be recovered.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle("Encrypted backup")
        .navigationBarTitleDisplayMode(.inline)
        .snapshotProtected()
    }

    private func encrypt() {
        encrypting = true
        let logN: UInt8 = useStronger ? NIP49.strongerLogN : NIP49.defaultLogN
        Task.detached {
            do {
                guard let nsec = SharedKeychain.loadNsec(for: pubkeyHex) else {
                    throw NSError(domain: "Clave", code: 1)
                }
                let sk = try SecretKey.parse(secretKey: nsec)
                let blob = try NIP49.encrypt(secretKey: sk,
                                             passphrase: passphrase,
                                             origin: .generatedInApp,
                                             logN: logN)
                await MainActor.run {
                    result = blob
                    encrypting = false
                    SharedStorage.setBackupStatus(.confirmed, for: pubkeyHex)
                }
            } catch let e {
                await MainActor.run {
                    error = "Encryption failed: \(e.localizedDescription)"
                    encrypting = false
                }
            }
        }
    }

    @ViewBuilder
    private func resultView(ncryptsec: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Backup created").font(.headline).foregroundStyle(.green)
            Text(ncryptsec)
                .font(.system(.caption, design: .monospaced))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .textSelection(.enabled)
            HStack {
                Button {
                    UIPasteboard.general.setItems(
                        [["public.utf8-plain-text": ncryptsec]],
                        options: [.localOnly: true,
                                  .expirationDate: Date().addingTimeInterval(120)]
                    )
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                Spacer()
                NavigationLink {
                    QRCodeView(content: ncryptsec)
                        .padding()
                        .navigationTitle("Backup QR")
                        .navigationBarTitleDisplayMode(.inline)
                        .snapshotProtected()
                } label: {
                    Label("Show QR", systemImage: "qrcode")
                }
                .buttonStyle(.bordered)
            }
            Text("Save this somewhere safe (password manager, written down). You'll need both the backup string AND your passphrase to restore.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
```

`QRCodeView` already exists in `Clave/Views/Components/QRCodeView.swift` — reuse.

- [ ] **Step 3: Update all `ExportKeySheet()` call sites**

`ExportKeySheet` had no `pubkeyHex` parameter before. Find call sites:

```bash
grep -rn "ExportKeySheet(" Clave --include="*.swift"
```

Pass the relevant account's `pubkeyHex` from each call site. Most are in `Settings`/`AccountDetailView`.

- [ ] **Step 4: Commit**

```bash
git add Clave/Views/Settings/ExportKeySheet.swift \
        Clave/Views/Backup/EncryptedBackupView.swift
git commit -m "$(cat <<'EOF'
feat(backup): refactor ExportKeySheet → three-option backup hub

ExportKeySheet becomes a backup hub with three ranked options:
- Encrypted backup (recommended) — passphrase → ncryptsec + QR
- Seed words — biometric-gated 12-word reveal (next task)
- Secret key (nsec) — demoted, extra confirmation (Task 12)

EncryptedBackupView handles the encrypted-export path: PassphraseEntry
collects pw + confirm + logN choice; encryption runs on a detached
task (logN=16 is ~1–2s, blocking the main actor would jank); on
success the user sees the ncryptsec string with Copy (local-only
clipboard, 120s expiry) and a QR. BackupStatus flips to .confirmed.

ExportKeySheet now takes a pubkeyHex parameter; all call sites
updated.

https://claude.ai/code/session_011AATP4KC3JVkuBvLCtL5zx
EOF
)"
```

### Task 11: `SeedWordsView` — biometric-gated 12-word display

**Files:**

- Create: `Clave/Views/Backup/SeedWordsView.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI

struct SeedWordsView: View {
    let pubkeyHex: String
    @State private var words: [String] = []
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !words.isEmpty {
                    Text("Write these down in order. Anyone with these words controls this account.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                              spacing: 10) {
                        ForEach(words.indices, id: \.self) { i in
                            HStack {
                                Text("\(i + 1).")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 22, alignment: .trailing)
                                Text(words[i])
                                    .font(.system(.body, design: .monospaced))
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    Text("Never type these into a website or share them with anyone.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if let error {
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                    Button("Try again") { load() }.buttonStyle(.bordered)
                } else {
                    ProgressView("Authenticating…")
                }
            }
            .padding()
        }
        .navigationTitle("Seed words")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load() }
        .snapshotProtected()
    }

    private func load() {
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let m = MnemonicStorage.read(for: pubkeyHex,
                                         reason: "Authenticate to view your seed words")
            DispatchQueue.main.async {
                if let m {
                    words = m.split(separator: " ").map(String.init)
                    SharedStorage.setBackupStatus(.confirmed, for: pubkeyHex)
                } else {
                    error = "Could not load seed words. Authentication was canceled or no mnemonic is stored."
                }
            }
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Clave/Views/Backup/SeedWordsView.swift
git commit -m "$(cat <<'EOF'
feat(backup): SeedWordsView — biometric-gated 12-word reveal

Triggers MnemonicStorage.read on appear, which prompts Face ID /
passcode. On success: shows the 12 words in a numbered 2-column grid
with safety copy. On cancel/no-entry: surfaces a retry button.

Successful reveal flips BackupStatus to .confirmed (viewing the words
implies the user has the means to back them up).

https://claude.ai/code/session_011AATP4KC3JVkuBvLCtL5zx
EOF
)"
```

### Task 12: `RawNsecRevealView` — demoted with extra confirmation

**Files:**

- Create: `Clave/Views/Backup/RawNsecRevealView.swift` (extracts the existing reveal-nsec UI from old `ExportKeySheet`)

Same biometric gate + reveal flow as today's `ExportKeySheet`, but preceded by a "Show raw secret key?" confirmation alert with explicit risk copy.

- [ ] **Step 1: Implement**

```swift
import SwiftUI
import LocalAuthentication

struct RawNsecRevealView: View {
    let pubkeyHex: String
    @State private var confirmed = false
    @State private var nsec: String?
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        Group {
            if let nsec {
                revealView(nsec: nsec)
            } else if !confirmed {
                confirmPrompt
            } else if let error {
                VStack(spacing: 12) {
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                    Button("Try again") { authenticate() }.buttonStyle(.bordered)
                }
                .padding()
            } else {
                ProgressView("Authenticating…")
            }
        }
        .navigationTitle("Secret key")
        .navigationBarTitleDisplayMode(.inline)
        .snapshotProtected()
    }

    private var confirmPrompt: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48)).foregroundStyle(.orange)
            Text("Show raw secret key?").font(.headline)
            Text("A raw nsec has no passphrase. Anyone who sees it can sign as you. Prefer the encrypted backup unless you need the raw format for a specific tool.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
            Button("I understand, show it") {
                confirmed = true
                authenticate()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding()
    }

    private func authenticate() {
        let ctx = LAContext()
        var err: NSError?
        let policy: LAPolicy = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication
        ctx.evaluatePolicy(policy, localizedReason: "Authenticate to view your raw secret key") { ok, e in
            DispatchQueue.main.async {
                if ok {
                    nsec = SharedKeychain.loadNsec(for: pubkeyHex)
                } else {
                    error = e?.localizedDescription ?? "Authentication failed"
                }
            }
        }
    }

    private func revealView(nsec: String) -> some View {
        // Same hardened clipboard + reveal as today's ExportKeySheet (~30 lines).
        // Local-only, 120s expiry, snapshot-protected.
        EmptyView()  // expand at implementation time
    }
}
```

- [ ] **Step 2: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat(backup): RawNsecRevealView — demoted reveal with extra gate

Reveals the raw nsec exactly as the pre-refactor ExportKeySheet did
(LAContext biometric + local-only clipboard with 120s expiry), but
behind an explicit "Show raw secret key?" confirmation that explains
the risk.

UX intent: the raw nsec stays available for users who need it (Damus
import path, etc.) but is no longer the default surface — encrypted
backup is.

https://claude.ai/code/session_011AATP4KC3JVkuBvLCtL5zx
EOF
)"
```

### Task 13: `AddAccountSheet` → restore-mode selector + import views

**Files:**

- Modify: `Clave/Views/Home/AddAccountSheet.swift`
- Create: `Clave/Views/Backup/SeedWordsImportView.swift`
- Create: `Clave/Views/Backup/EncryptedBackupImportView.swift`

Existing sheet has two modes (Generate / Paste nsec). Add two restore modes (Seed words / Encrypted backup).

- [ ] **Step 1: Add the segmented picker / list selector**

In `AddAccountSheet.swift`, replace the existing two-mode picker with four:

```swift
enum Mode: String, CaseIterable {
    case generate     = "Generate new"
    case nsec         = "Paste nsec"
    case seedWords    = "Restore seed words"
    case encrypted    = "Restore encrypted backup"
}
```

When `mode == .seedWords` or `.encrypted`, push the corresponding import view.

- [ ] **Step 2: Implement `SeedWordsImportView`**

```swift
import SwiftUI

struct SeedWordsImportView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var words: String = ""
    @State private var error: String?
    @State private var importing = false

    var body: some View {
        Form {
            Section {
                TextEditor(text: $words)
                    .frame(minHeight: 120)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("12 or 24 BIP-39 words, separated by spaces")
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Section {
                Button {
                    importNow()
                } label: {
                    if importing { ProgressView() }
                    else { Text("Restore account") }
                }
                .disabled(!shapeValid || importing)
            }
        }
        .navigationTitle("Restore from seed words")
        .navigationBarTitleDisplayMode(.inline)
        .snapshotProtected()
    }

    private var shapeValid: Bool {
        BIP39.isShapeValid(words.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private func importNow() {
        importing = true
        Task.detached {
            do {
                _ = try await MainActor.run {
                    try appState.importMnemonic(words: words, label: nil)
                }
                await MainActor.run { importing = false; dismiss() }
            } catch let e {
                await MainActor.run {
                    error = e.localizedDescription
                    importing = false
                }
            }
        }
    }
}
```

- [ ] **Step 3: Implement `EncryptedBackupImportView`**

Symmetric: TextEditor for the ncryptsec, `PassphraseEntry(mode: .decrypt)`, "Restore" button → `appState.importEncryptedKey(...)`.

- [ ] **Step 4: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat(backup): AddAccountSheet — restore from seed words / encrypted backup

Two new modes added to AddAccountSheet alongside Generate / Paste:
- SeedWordsImportView: 12/24-word entry, shape-validated against the
  BIP-39 wordlist before the Restore button enables; checksum failures
  surface from Keys.fromMnemonic via the existing alert flow
- EncryptedBackupImportView: ncryptsec text entry + PassphraseEntry in
  .decrypt mode; runs NIP49.decrypt; wrong-passphrase surfaces clearly

Both use the import* methods added in Tasks 7–8.

https://claude.ai/code/session_011AATP4KC3JVkuBvLCtL5zx
EOF
)"
```

### Task 14: `BackupConfirmStep` in onboarding

**Files:**

- Create: `Clave/Views/Backup/BackupConfirmStep.swift`
- Modify: `Clave/Views/Onboarding/OnboardingView.swift`

After generation (now mnemonic-backed), insert a write-down + verify-3-random-words step. On success, flip `BackupStatus → .confirmed`. Skippable with a clear warning that fires only once ("You can do this later from Settings").

- [ ] **Step 1: Implement `BackupConfirmStep`**

```swift
import SwiftUI

struct BackupConfirmStep: View {
    let pubkeyHex: String
    let onConfirmed: () -> Void
    let onSkipped: () -> Void

    @State private var words: [String] = []
    @State private var phase: Phase = .show

    enum Phase { case show, verify }

    var body: some View {
        Group {
            switch phase {
            case .show:    showWordsView
            case .verify:  verifyView
            }
        }
        .navigationTitle("Back up your account")
        .navigationBarTitleDisplayMode(.inline)
        .snapshotProtected()
        .onAppear {
            // No biometric here — the user JUST created this account; immediate
            // reveal is appropriate. Read via the DEBUG-or-internal path if
            // present, else fall back to MnemonicStorage.read with a passive
            // localizedReason.
            if let m = MnemonicStorage.read(for: pubkeyHex,
                                            reason: "Showing your new seed words") {
                words = m.split(separator: " ").map(String.init)
            }
        }
    }

    private var showWordsView: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Write these 12 words down on paper and store them somewhere safe. They're the only way to recover this account if you lose your phone.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                          spacing: 8) {
                    ForEach(words.indices, id: \.self) { i in
                        HStack {
                            Text("\(i + 1).").font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary).frame(width: 22, alignment: .trailing)
                            Text(words[i]).font(.system(.body, design: .monospaced))
                            Spacer()
                        }
                        .padding(8).background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                Button("I've written them down → Verify") { phase = .verify }
                    .buttonStyle(.borderedProminent)
                Button("Skip for now (less safe)") {
                    SharedStorage.setBackupStatus(.skipped, for: pubkeyHex)
                    onSkipped()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private var verifyView: some View {
        // Pick 3 random indices; render fill-in-the-blanks; on correct → onConfirmed
        // + setBackupStatus(.confirmed). On wrong → soft error + retry.
        // (~60 lines)
        EmptyView()
    }
}
```

- [ ] **Step 2: Wire into `OnboardingView`**

After successful `createAccount`, push `BackupConfirmStep(pubkeyHex: ..., onConfirmed: { dismiss / advance }, onSkipped: { dismiss / advance })`.

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat(backup): onboarding BackupConfirmStep (write-down + verify 3 words)

Two-phase step inserted after createAccount in OnboardingView:
1. Show 12 words in a numbered grid + safety copy
2. Verify by filling in 3 random word indices

Success → BackupStatus.confirmed; explicit Skip → BackupStatus.skipped
(distinct from .notBackedUp so we soften repeat nudges but still flag
the account as not fully secured).

Mnemonic is read via MnemonicStorage immediately after creation —
biometric prompt fires but is expected ("Showing your new seed words"
is a sensible reason). UX cost is one extra Face ID at onboarding;
worth it.

https://claude.ai/code/session_011AATP4KC3JVkuBvLCtL5zx
EOF
)"
```

### Task 15: Backup-status surfacing in `AccountDetailView` + `SlimIdentityBar`

**Files:**

- Modify: `Clave/Views/Settings/AccountDetailView.swift`
- Modify: `Clave/Views/Home/SlimIdentityBar.swift`

- [ ] **Step 1: Add `Backup` section to `AccountDetailView`**

```swift
Section("Backup") {
    HStack {
        Image(systemName: status == .confirmed ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
            .foregroundStyle(status == .confirmed ? .green : .orange)
        VStack(alignment: .leading, spacing: 2) {
            Text(status == .confirmed ? "Backed up" : "Not backed up")
                .font(.subheadline).fontWeight(.medium)
            Text(status == .confirmed
                 ? "You can recover this account with your backup."
                 : "If you lose this phone, this account cannot be recovered.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    NavigationLink {
        ExportKeySheet(pubkeyHex: account.pubkeyHex)
    } label: {
        Label(status == .confirmed ? "Manage backup" : "Back up now",
              systemImage: "lock.shield")
    }
}
```

- [ ] **Step 2: Add the warning badge to `SlimIdentityBar`**

A small orange "!" pill next to the current account's avatar when status is `.notBackedUp` (NOT `.skipped` — we honor explicit Skip). Tap → navigates to `AccountDetailView`.

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat(backup): surface BackupStatus in AccountDetailView + SlimIdentityBar

AccountDetailView gains a Backup section: status row + "Back up now"
CTA when not confirmed, "Manage backup" otherwise. Both link to the
refactored ExportKeySheet.

SlimIdentityBar shows an orange "!" badge on the current account
avatar when status == .notBackedUp. Tap routes to AccountDetail.
.skipped accounts do NOT show the badge — the user explicitly opted
out, repeated nudges are annoying.

https://claude.ai/code/session_011AATP4KC3JVkuBvLCtL5zx
EOF
)"
```

### Task 16: README + docs updates

**Files:**

- Modify: `README.md` (What works end-to-end section)

- [ ] **Step 1: Add to "What works end-to-end" list**

```
- **Key backup & recovery** — encrypted export (NIP-49 `ncryptsec` + QR), 12-word seed phrase (NIP-06) for newly-generated keys, restore from either format; mnemonic stored biometric-gated; raw `nsec` export still available behind an extra confirmation
```

- [ ] **Step 2: Commit**

```bash
git commit -m "$(cat <<'EOF'
docs: README — Tier 1 key backup capabilities

Document the Phase 1 backup surface in "What works end-to-end":
NIP-49 encrypted export + QR, NIP-06 seed words for new keys,
restore-from-either, biometric-gated mnemonic storage.

https://claude.ai/code/session_011AATP4KC3JVkuBvLCtL5zx
EOF
)"
```

### Phase 1 smoke-test pass (real device)

Before opening the Phase 1 PR, run the following on a physical iPhone:

1. **Generate new account** → confirm 12 words appear → confirm verify-3-words step succeeds → confirm `.confirmed` status (no orange badge on the identity bar).
2. **Export encrypted backup** → enter passphrase → confirm ncryptsec produced → Copy + QR work.
3. **Wipe app + reinstall** → onboarding "I have a backup" → Restore from seed words → npub matches the original.
4. **Wipe again** → Restore from encrypted backup with the passphrase from step 2 → npub matches.
5. **Import paste-nsec** → confirm seed words option is disabled with the correct messaging.
6. **Existing pre-Phase-1 account** (from a TestFlight backup): seed words disabled, encrypted backup works, raw nsec export still works.
7. **NSE signing still works** (publish a kind:24133 from any paired client → app stays backgrounded → request signs) — non-regression.

---

## Phase 2 — Encrypted iCloud backup (CloudKit)

**Goal of this phase:** layer opt-in iCloud backup on top of Phase 1's `ncryptsec` primitive. Each opted-in account writes a `CKBackupRecord` (ncryptsec + npub + label + createdAt) to the user's private CloudKit database. iCloud (and Apple) only ever see ciphertext; the passphrase never leaves the device. Restore: fresh install → "Restore from iCloud" lists the records → user picks one → enters the passphrase → decrypted locally.

**Estimated total tasks:** 9.

**Phase 2 acceptance criteria:**

- Opt-in toggle in `AccountDetailView` writes a `CKBackupRecord` to `privateCloudDatabase` containing only the ncryptsec (verified by inspecting CloudKit Dashboard)
- `AddAccountSheet` → "Restore from iCloud" lists all records under the signed-in iCloud account (across pubkeys)
- Restore with the correct passphrase produces the same npub as the original
- Restore with a wrong passphrase surfaces a clear "wrong passphrase" error and does not consume the record
- The `Clave` target gains the iCloud entitlement; the `ClaveNSE` target does NOT (verified in build settings)
- "No iCloud account" / "iCloud unavailable" / "quota exceeded" each show a sensible message; backup state does not silently flip
- Phase 1 acceptance criteria continue to pass

### Task P2.1: CloudKit entitlement + container

**Files:**

- Modify: `Clave/Clave.entitlements`
- Modify: project build settings (CloudKit container identifier)

- [ ] Add `com.apple.developer.icloud-services = [ "CloudKit" ]` and `com.apple.developer.icloud-container-identifiers = [ "iCloud.dev.nostr.clave" ]` to `Clave.entitlements`. NSE target is **explicitly not** modified — confirm the NSE's entitlements file shows no CloudKit keys.
- [ ] In Xcode → Signing & Capabilities → add iCloud capability → CloudKit → container `iCloud.dev.nostr.clave`. Create the container in the Apple Developer portal if it doesn't exist.
- [ ] Build + run. Expected: container appears in CloudKit Dashboard.

Commit only the entitlements file change:

```bash
git add Clave/Clave.entitlements
git commit -m "$(cat <<'EOF'
build(backup): add CloudKit entitlement to the Clave target

Adds com.apple.developer.icloud-services = CloudKit and the container
identifier iCloud.dev.nostr.clave to Clave.entitlements. NSE target
unchanged — backup is a main-app concern only.

https://claude.ai/code/session_011AATP4KC3JVkuBvLCtL5zx
EOF
)"
```

### Task P2.2: `CKBackupRecord` model

**Files:**

- Create: `Clave/Backup/CloudKitBackup.swift` (CKBackupRecord struct only this task; service in P2.3)
- Test: `ClaveTests/CKBackupRecordTests.swift`

```swift
import CloudKit

struct CKBackupRecord {
    /// CloudKit record-id derived from pubkey hex — stable, lets re-saves
    /// upsert rather than duplicate.
    static let recordType = "AccountBackup"

    let pubkeyHex: String
    let npub: String
    let label: String?
    let ncryptsec: String
    let createdAt: Date

    func toCKRecord() -> CKRecord {
        let id = CKRecord.ID(recordName: "backup_\(pubkeyHex)")
        let r = CKRecord(recordType: Self.recordType, recordID: id)
        r["pubkeyHex"] = pubkeyHex as NSString
        r["npub"]      = npub as NSString
        r["label"]     = (label ?? "") as NSString
        r["ncryptsec"] = ncryptsec as NSString
        r["createdAt"] = createdAt as NSDate
        return r
    }

    init(pubkeyHex: String, npub: String, label: String?,
         ncryptsec: String, createdAt: Date = .init()) {
        self.pubkeyHex = pubkeyHex; self.npub = npub
        self.label = label; self.ncryptsec = ncryptsec
        self.createdAt = createdAt
    }

    init?(_ record: CKRecord) {
        guard let pk = record["pubkeyHex"] as? String,
              let np = record["npub"] as? String,
              let nc = record["ncryptsec"] as? String,
              let dt = record["createdAt"] as? Date else { return nil }
        self.pubkeyHex = pk; self.npub = np
        self.label = (record["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.ncryptsec = nc; self.createdAt = dt
    }
}
```

Tests pin the record-type string, recordID derivation, and round-trip.

### Task P2.3: `iCloudBackupService`

**Files:**

- Modify: `Clave/Backup/CloudKitBackup.swift` (add the service)
- Test: `ClaveTests/iCloudBackupServiceTests.swift`

```swift
import CloudKit

enum iCloudBackupError: Error {
    case notSignedIn
    case quotaExceeded
    case underlying(Error)
}

protocol iCloudBackupServicing {
    func accountStatus() async throws -> CKAccountStatus
    func save(_ record: CKBackupRecord) async throws
    func list() async throws -> [CKBackupRecord]
    func delete(pubkeyHex: String) async throws
}

final class iCloudBackupService: iCloudBackupServicing {
    private let container: CKContainer
    private var db: CKDatabase { container.privateCloudDatabase }
    init(container: CKContainer = .default()) { self.container = container }

    func accountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }

    func save(_ record: CKBackupRecord) async throws {
        do {
            _ = try await db.modifyRecords(saving: [record.toCKRecord()],
                                           deleting: [],
                                           savePolicy: .changedKeys)
        } catch let e as CKError where e.code == .quotaExceeded {
            throw iCloudBackupError.quotaExceeded
        } catch let e as CKError where e.code == .notAuthenticated {
            throw iCloudBackupError.notSignedIn
        } catch {
            throw iCloudBackupError.underlying(error)
        }
    }

    func list() async throws -> [CKBackupRecord] {
        let q = CKQuery(recordType: CKBackupRecord.recordType,
                        predicate: NSPredicate(value: true))
        let (matches, _) = try await db.records(matching: q)
        return matches.compactMap { (_, result) -> CKBackupRecord? in
            (try? result.get()).flatMap { CKBackupRecord($0) }
        }
    }

    func delete(pubkeyHex: String) async throws {
        let id = CKRecord.ID(recordName: "backup_\(pubkeyHex)")
        try await db.deleteRecord(withID: id)
    }
}
```

Tests use a `MockICloudBackupService` conforming to the protocol — service-contract tests live behind the protocol; the real CloudKit calls are validated in the Phase 2 smoke test.

### Task P2.4: Opt-in toggle in `AccountDetailView`

**Files:**

- Modify: `Clave/Views/Settings/AccountDetailView.swift`
- Create: `Clave/Views/Backup/iCloudBackupToggle.swift`

The toggle requires a passphrase before flipping on (it must encrypt). UX:

1. User flips Toggle → presents a sheet with `PassphraseEntry(mode: .create)` + "Back up to iCloud"
2. On submit: encrypt → save via `iCloudBackupService.save` → toggle persists ON
3. Status row reads "Backed up to iCloud ✓ (yesterday)"; tap → re-enter passphrase to re-back-up (rotates blob)
4. Flip OFF → confirmation alert → `iCloudBackupService.delete`

Persist the per-account opt-in flag in `SharedStorage` (`isiCloudBackedUp(for:)`).

### Task P2.5: "Restore from iCloud" in `AddAccountSheet`

**Files:**

- Modify: `Clave/Views/Home/AddAccountSheet.swift`
- Create: `Clave/Views/Backup/iCloudRestoreView.swift`

Adds a fifth restore mode. On entry:

1. Call `iCloudBackupService.accountStatus` → if not `.available`, show clear message + Settings deep link
2. Call `iCloudBackupService.list` → show records with avatar (via pubkey-derived gradient), label, npub-prefix, "backed up <date>"
3. User selects N records (multi-select) → enter passphrase per record (different accounts can have different passphrases — handle one-at-a-time entry)
4. For each record: `NIP49.decrypt` → if success, save to local Keychain + add to `accounts` array + flip `BackupStatus = .confirmed`; if wrong passphrase, surface error and leave the record selectable for retry
5. On finish: navigate to Home

### Task P2.6: iCloud restore flow — `restoreFromiCloud(record:passphrase:)`

**Files:**

- Modify: `Clave/AppState+AccountManager.swift`

Single-record restore method called by `iCloudRestoreView` per record:

```swift
@discardableResult
func restoreFromiCloud(record: CKBackupRecord,
                       passphrase: String) throws -> Account {
    let sk = try NIP49.decrypt(record.ncryptsec, passphrase: passphrase)
    let pk = try PublicKey.fromSecretKey(sk).toHex()
    if accounts.contains(where: { $0.pubkeyHex == pk }) {
        throw AccountError.duplicateAccount
    }
    try SharedKeychain.saveNsec(try sk.toBech32(), for: pk)
    // No mnemonic — iCloud holds the ncryptsec, not the mnemonic.
    let account = Account(pubkeyHex: pk,
                          displayLabel: record.label ?? Self.defaultLabel(),
                          createdAt: record.createdAt.timeIntervalSince1970)
    accounts.append(account)
    persistAccounts()
    SharedStorage.setBackupStatus(.confirmed, for: pk)
    SharedStorage.setiCloudBackedUp(true, for: pk)
    return account
}
```

### Task P2.7: Backup-status indicator updates

**Files:**

- Modify: `Clave/Views/Settings/AccountDetailView.swift`

Update the Backup section copy to distinguish "Backed up (export only)" vs "Backed up to iCloud" — the latter survives a wiped device.

### Task P2.8: Edge cases

- [ ] "No iCloud account": show actionable message ("Sign in to iCloud in Settings to enable backup")
- [ ] "Quota exceeded": surface message + recommend deleting old backups
- [ ] Conflict on save (another device modified the same record): re-fetch and merge by `createdAt` newer-wins
- [ ] Schema migration if `CKBackupRecord` fields change later: include a `schemaVersion` field initialized to 1

Each as a small targeted test in `iCloudBackupServiceTests` + smoke test on a real device.

### Task P2.9: Documentation

**Files:**

- Modify: `README.md` (note iCloud backup in "What works")
- Modify: `docs/integrations.md` (informational: a Clave user may now restore on any of their iPhones)

### Phase 2 smoke-test pass

1. Enable iCloud backup on an account → enter passphrase → check CloudKit Dashboard shows the `AccountBackup` record with the ncryptsec field
2. Sign out of iCloud → enable toggle → confirm clear "Sign in to iCloud" message
3. Wipe app → "Restore from iCloud" → select the record → enter correct passphrase → npub matches
4. Wrong passphrase on restore → clear error, record still listed
5. Disable backup → toggle off → confirm record deleted from CloudKit Dashboard
6. NSE signing still works post-restore — non-regression
7. Confirm NSE target's entitlements file is unchanged (no CloudKit keys)

---

## Cross-phase notes

- **Sequencing reminder:** Phase 1 ships first as an independent PR; Phase 2 builds on Phase 1's primitives (`NIP49`, `BackupStatus`) and ships as a separate PR.
- **Spec drift:** if the spec changes during implementation, update the spec FIRST in a separate commit, then continue the plan against the updated spec. Don't silently diverge.
- **Existing TestFlight users:** Phase 1 doesn't migrate existing keys (no mnemonic to fabricate). Existing accounts simply show seed words disabled and steer to encrypted backup / iCloud. Phase 2 lets them back up to iCloud without any data migration.
- **Multi-relay / Tier 3 work** (the other backlog item) is independent of this plan — both can proceed in parallel without conflicts.
