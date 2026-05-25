# Key Backup & Recovery — encrypted export, seed words, QR, and encrypted iCloud

_2026-05-22 — design spec for Tier 1 of the Amber-parity gap analysis. Clave currently holds the **only** copy of a user's key (iOS Keychain, `ThisDeviceOnly`) with no recovery path beyond copying a raw `nsec` to the clipboard. This spec closes that gap with four layered capabilities: (1) NIP-49 encrypted-key export (`ncryptsec`), (2) NIP-06 seed-phrase backup & restore for newly-generated keys, (3) QR export of the encrypted blob, and (4) opt-in **encrypted** iCloud backup where iCloud only ever sees ciphertext. It deliberately does **not** change how the working signing key is stored._

## Context

Clave is a key-custody app whose entire value proposition is "your nsec never leaves the device." Today that property is enforced literally:

- The signing key is stored one-entry-per-account in the shared Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (`SharedKeychain.swift:24,97`) — **not** iCloud-synced, **not** in device backups.
- New keys are generated as raw entropy via `Keys.generate()` (`AppState+AccountManager.swift:197`). There is no mnemonic anywhere in the pipeline.
- Keys are imported by pasting an `nsec`/hex secret (`AppState+AccountManager.swift:147`, `AddAccountSheet.swift`).
- The only export is the raw `nsec` shown in `ExportKeySheet.swift` — biometric-gated (`ExportKeySheet.swift:101-130`), copied to a local-only pasteboard that auto-expires after 120s (`:50-70`). No encrypted form, no QR, no seed words, and **no restore flow at all**.

The consequence: if the phone is lost, wiped, or the app is deleted, the identity is gone permanently. Nostr keys cannot be rotated or reset. This is the single largest gap versus Amber, which treats backup as a first-class onboarding step and offers the key as mnemonic seed words, an `ncryptsec`, or a QR code, gated behind device authentication.

This spec is **additive and orthogonal to the signing hot path**. The Notification Service Extension (NSE) keeps reading the same `ThisDeviceOnly` Keychain entry it reads today; nothing here touches the ~24 MB / 30 s NSE budget. All backup and restore work lives in the main app, where the full `rust-nostr-swift` SDK is already linked.

## Goals

- **Encrypted export (NIP-49).** Let the user export any account's key as an `ncryptsec` — passphrase-encrypted, safe to write down, store in a password manager, or print. This replaces raw-`nsec`-to-clipboard as the *recommended* export.
- **Seed-phrase backup (NIP-06).** For keys Clave generates going forward, generate them **from a BIP-39 mnemonic** so the user can back up 12/24 words and restore on any NIP-06 client. This is the recovery format most Nostr users expect.
- **Restore.** A first-class "I have a backup" path on onboarding and Add-Account: restore from seed words, from an `ncryptsec` (+ passphrase), or from iCloud.
- **QR export.** Render the `ncryptsec` (never the raw `nsec` by default) as a QR for device-to-device or paper transfer.
- **Encrypted iCloud backup (opt-in).** Store the `ncryptsec` blob in the user's private iCloud so a lost device is recoverable, while preserving the security pitch: iCloud (and Apple) only ever hold ciphertext; the passphrase never leaves the device.
- **Make backup unmissable.** Surface a "this account is not backed up" state and prompt for backup during onboarding — matching Amber's onboarding backup step.
- **Preserve the working-key storage model.** The live signing key stays `ThisDeviceOnly` in the Keychain. Backup is a separate, explicit, user-initiated copy.

## Non-goals

- **No change to working-key storage.** We are not flipping the Keychain item to `kSecAttrSynchronizable` (that is the rejected "Option A" — see "iCloud backup" below). The signing key remains device-only; only an encrypted *backup* leaves the device, and only on explicit opt-in.
- **No silent/automatic cloud backup.** iCloud backup is opt-in per account, never default-on. A user who wants zero cloud exposure keeps the manual seed/`ncryptsec` paths.
- **No deriving multiple accounts from one seed (this round).** Clave's accounts are independent keys today. Per-account-index derivation (`m/44'/1237'/<account>'/0/0`) from a single master mnemonic is a coherent future feature but changes the account model; see "Out of scope."
- **No FROST / key-sharding, no NIP-41 migration/revocation.** These are real parts of the modern Nostr key-management story but are separate initiatives; see "Future / related NIPs."
- **No server involvement.** The proxy never sees keys, ciphertext, or passphrases. iCloud backup uses Apple's CloudKit private database / key-value store directly from the device.

## NIP grounding (current as of 2026-05)

| NIP | Role here | Key facts we depend on |
|---|---|---|
| **NIP-49** — Private Key Encryption | Encrypted export + iCloud blob | Binary layout: `version=0x02` ‖ `log_n` (1 byte) ‖ `salt` (16 B) ‖ `nonce` (24 B) ‖ `key_security_byte` (1 B, as AAD) ‖ ciphertext (32 B key + 16 B Poly1305 tag) = 91 bytes; KDF `scrypt(p=1, r=8, log_n)`; cipher **XChaCha20-Poly1305**; password **NFKC**-normalized; bech32 HRP `ncryptsec`. |
| **NIP-06** — Key derivation from seed | Seed-phrase backup/restore | BIP-39 mnemonic → BIP-32 derivation at **`m/44'/1237'/<account>'/0/0`** (SLIP-44 coin type 1237). Account index 0 for the basic single-key case. |
| **NIP-44** — Versioned encryption | (Context) already implemented in `LightCrypto.swift` for the signing path; unrelated to at-rest key encryption. |
| **NIP-41** — Key migration/revocation | Future/related | Still a draft PR; lets a user migrate to a new key via a pre-designated recovery key. Complements backup but out of scope. |

`key_security_byte` values: `0x00` = key was handled insecurely at some point; `0x01` = handled securely throughout; `0x02` = unknown. Clave sets **`0x01`** for keys generated in-app that never left the secure path, and **`0x02`** for keys imported by paste (we can't attest to their prior handling).

## Crypto availability — reuse `rust-nostr`, don't hand-roll

The main app links `nostr-sdk-swift` (rust-nostr) 0.44.2, which is the natural home for both formats:

- **NIP-49 (confirmed exposed in 0.44.2):** `EncryptedSecretKey` is a UniFFI-exported class with `init(secretKey: SecretKey, password: String, logN: UInt8, keySecurity: KeySecurity) throws`, `EncryptedSecretKey.fromBech32(_:)`, `decrypt(password:)`, `toBech32()`, `version()`, and `keySecurity()`. A `SecretKey.encrypt(password:)` convenience also exists but hardcodes `logN=16` and `keySecurity=.unknown`; we use the explicit initializer so we control both. The `KeySecurity` enum values are **`.weak`** / **`.medium`** / **`.unknown`** (mapping to NIP-49's `0x00` / `0x01` / `0x02`) — Clave sets **`.medium`** for in-app-generated keys and **`.unknown`** for keys imported by paste. `EncryptedSecretKeyVersion.v2` is exposed. This avoids hand-implementing scrypt + **XChaCha20-Poly1305**, neither of which is available in Apple's CryptoKit (CryptoKit's `ChaChaPoly` is ChaCha20-Poly1305 with a 96-bit nonce — **not** the 192-bit XChaCha20 variant NIP-49 requires, and there is no scrypt primitive).
- **NIP-06 (partially exposed in 0.44.2):** `Keys.fromMnemonic(mnemonic: String, passphrase: String?, account: UInt32?, typ: UInt32?, index: UInt32?) throws -> Keys` is exposed — derivation works at the standard NIP-06 path `m/44'/1237'/account'/typ/index`. **Mnemonic generation is NOT exposed** in 0.44.2 (also absent on master at verification time). We need a small BIP-39 entropy → words helper on the Clave side: either a vetted small Swift Package, or ~100 lines + the canonical BIP-39 English wordlist as a checked-in resource. This is materially smaller than vendoring NIP-49 (no scrypt, no XChaCha20) — it's deterministic encoding of secure random bytes against a fixed wordlist, with public test vectors.

> **Verification status (2026-05-25):** NIP-49 confirmed in the v0.44.2 Swift bindings (source: `rust-nostr/nostr-sdk-ffi` at `v0.44.2`, `src/protocol/nips/nip49.rs`). NIP-06 derivation confirmed (`Keys.fromMnemonic` at `src/protocol/nips/nip06.rs`); mnemonic generation gap also confirmed — handled by a small BIP-39 helper in Clave, scoped in the implementation plan.

Because backup/restore runs only in the main app (never the NSE), pulling these from the heavier rust-nostr FFI is free of the NSE's binary-size/RAM constraints.

## Capability 1 — Encrypted export (NIP-49 `ncryptsec`)

Refactor `ExportKeySheet` from "reveal raw nsec" to a backup hub with three clearly-ranked options:

1. **Encrypted backup (`ncryptsec`)** — *recommended.* User sets a passphrase (with a strength meter and a confirm field); Clave produces the `ncryptsec1…` string. Offer Copy (local-only pasteboard, 120 s expiry, matching today's hardening) and "Show QR" (Capability 3).
2. **Seed words** — shown only when the account has an associated mnemonic (Capability 2). Hidden/greyed with an explanatory note for legacy/imported keys.
3. **Raw secret key (`nsec`)** — retained but demoted: behind an extra "I understand the risk" confirmation, since a raw nsec has no passphrase gate once revealed.

Passphrase handling: NFKC-normalize before passing to the KDF (NIP-49 requirement, so the same words entered on another client/computer reproduce the key). Choose `log_n` for a mobile-acceptable derive time — recommend a default around **`log_n = 16`** (≈1–2 s on a modern iPhone) with an optional "stronger (slower)" toggle at `18`. Document that `log_n` is embedded in the blob, so a backup made at one cost factor still decrypts regardless of the device that restores it.

Biometric gate (existing `LAContext` flow in `ExportKeySheet.swift:101-130`) stays in front of *all* reveal/export actions.

## Capability 2 — Seed-phrase backup & restore (NIP-06)

This is the highest-value addition and the one with a real architectural decision attached.

**The constraint:** today `Keys.generate()` produces raw entropy with no mnemonic (`AppState+AccountManager.swift:197`). A raw key **cannot** be turned back into BIP-39 words after the fact. So seed words are only possible for keys created *through a mnemonic*.

**Decision — generate-from-mnemonic going forward:**

- New key generation changes from `Keys.generate()` to: generate a BIP-39 mnemonic → derive the key at `m/44'/1237'/0'/0/0` → store the derived `nsec` in the Keychain exactly as today.
- The mnemonic itself is **not** persisted to the Keychain by default. It is shown once at generation time inside a backup-confirmation step (write-it-down + verify-N-words), then discarded from memory. (Persisting the mnemonic is an option that trades a larger secret-at-rest for the ability to re-show words later — discussed in Risks.)
- To support "show seed words later" and seed-based iCloud backup without persisting plaintext words, the **mnemonic can be carried inside the same NIP-49 envelope** (encrypt the mnemonic phrase rather than the 32-byte key) — keeping a single passphrase-protected artifact. The plan picks one of {don't persist, persist encrypted}; the spec's position is **persist encrypted** so "show my seed words" and encrypted iCloud both work, and the user has one passphrase to remember.

**Legacy / imported keys:** keys generated by current builds (raw entropy) and any pasted `nsec` have no mnemonic. For these, seed words are unavailable by construction; the UI says so plainly and steers the user to `ncryptsec` + iCloud backup instead. No silent migration — we never fabricate a mnemonic for an existing key.

**Restore flow** (new onboarding/Add-Account branch "I already have a key"):

- *From seed words:* enter 12/24 words → derive at the NIP-06 path → save to Keychain → fetch profile as usual.
- *From `ncryptsec`:* paste/scan + passphrase → decrypt → save.
- *From iCloud:* see Capability 4.
- *From raw `nsec`:* the existing paste path (`AddAccountSheet`), unchanged.

## Capability 3 — QR export

Render the **`ncryptsec`** (never the raw `nsec` by default) using the existing `QRCodeView` component. Pair with the camera scanner (`QRScannerView`) on the restore side so a user can move an encrypted key device-to-device or restore from a printed backup. A raw-`nsec` QR is available only behind the same extra risk confirmation as the raw-`nsec` text reveal, with a `snapshotProtected()` wrapper (already used on `ExportKeySheet`).

## Capability 4 — Encrypted iCloud backup (the "Option B" decision)

Two ways to put a key in iCloud; we choose the one that preserves the security story.

**Option A — iCloud Keychain sync (rejected as the headline mechanism).** Flip the working key to `kSecAttrAccessibleAfterFirstUnlock` + `kSecAttrSynchronizable = true`. Apple then syncs it via end-to-end-encrypted iCloud Keychain. ~5 lines, no passphrase, automatic. But it contradicts "the nsec never leaves the device," shifts trust to the Apple-account + passcode-escrow boundary, offers no app-controlled passphrase, and the Nostr-native audience routinely disables iCloud Keychain. May be offered later as a clearly-labeled secondary convenience, but it is **not** the recommended path and it must never be silently enabled.

**Option B — app-encrypted blob in iCloud (chosen).** Store the **`ncryptsec`** (Capability 1's output) in the user's private iCloud. Apple/iCloud only ever see ciphertext; the passphrase never leaves the device; decryption happens on-device during restore.

- **Storage:** `CKContainer.privateCloudDatabase` (CloudKit), one record per account keyed by pubkey, holding the `ncryptsec` string + minimal metadata (npub, optional display name, `created_at`). CloudKit gives per-account records and clean multi-device sync. `NSUbiquitousKeyValueStore` is a lighter alternative (an `ncryptsec` is ~100 bytes, far under the 1 MB limit) acceptable for a minimal first cut; the plan picks one. **Not** iCloud Drive (user-visible ciphertext file is needless exposure).
- **Restore:** on a fresh install, "Restore from iCloud" lists the pubkeys/labels found in the private DB; the user picks one and enters the passphrase to decrypt locally into the Keychain.
- **Threat model:** a total iCloud-account compromise yields only `ncryptsec` blobs — each gated by the user's passphrase and scrypt work factor. Apple cannot read them. This is materially stronger than Option A's "trust Apple's escrow."
- **Messaging:** opt-in toggle per account in `AccountDetailView`/Settings, with copy like *"Back up an encrypted copy to your iCloud. Your passphrase never leaves this device — Apple and Clave can't read it."* A "backed up to iCloud ✓ / not backed up" indicator per account.
- **NSE untouched:** backup/restore is main-app only. The CloudKit entitlement and code are not added to the NSE target.

**Defense-in-depth (optional, flagged):** XOR the scrypt-derived key with a device-stored secret so the iCloud blob is useless without *both* the passphrase and that device. This is strictly stronger against iCloud compromise but **breaks restore on a new device** (the device secret is gone with the old phone) — i.e. it converts iCloud backup into same-device-only redundancy. Because that defeats the primary purpose (recover a *lost* device), the spec's default is **passphrase-only**; the device-secret variant is offered, if at all, only as an explicit "this backup can only be restored on this device" mode.

## Security model

**What still never leaves the device in plaintext:** the raw private key and any mnemonic. The working key stays `ThisDeviceOnly` in the Keychain (`SharedKeychain.swift`).

**What may leave the device (only on explicit user action):** an `ncryptsec` — i.e. ciphertext under a user passphrase via scrypt + XChaCha20-Poly1305. This can go to: the clipboard (local-only, 120 s expiry), a QR code, or the user's private iCloud.

**What iCloud / Apple can see (Option B):** the `ncryptsec` ciphertext + npub + optional label. Not the key, not the passphrase, not the mnemonic.

**What the proxy can see:** nothing new. The proxy is not involved in backup at all.

**Passphrase is the security boundary** for every off-device artifact. We enforce a minimum length / strength and surface a meter; we NFKC-normalize; we never store the passphrase. A weak passphrase yields a weak backup — call this out in UI copy.

**Irrecoverability is by design:** a forgotten passphrase means the `ncryptsec`/iCloud backup is unrecoverable, and a lost seed phrase (for not-persisted mnemonics) is unrecoverable. This is the correct property for a custody app and must be stated plainly at backup time.

## Risks / open questions

1. **BIP-39 mnemonic generation source.** rust-nostr 0.44.2 Swift bindings expose `Keys.fromMnemonic` (derivation) but NOT mnemonic generation — verified 2026-05-25; see Crypto section. The plan needs a BIP-39 entropy→words helper: **(a)** add a small vetted Swift BIP-39 package, or **(b)** hand-roll ~100 lines + the canonical English wordlist as a checked-in resource. Default is (a) with the package named in the plan; (b) is the fallback if no maintained option meets the audit bar. Risk is bounded — BIP-39 has public test vectors and Clave can pin both implementations to them.
2. **scrypt cost vs. mobile UX.** `log_n=16` derive time varies across device generations. Need to measure on the oldest supported device; pick a default that's tolerable (<~2 s) without being weak. The cost factor travels in the blob, so restores are unaffected by the choice made at backup time.
3. **Persist the mnemonic, or not?** Persisting it (encrypted) enables "show seed words later" and seed-based iCloud, at the cost of a second secret-at-rest. Not persisting it minimizes attack surface but means words are shown exactly once. Spec leans "persist encrypted"; confirm with product.
4. **Legacy-key story.** Existing testers' keys have no mnemonic. They get `ncryptsec` + iCloud only. Is an explicit "rotate to a mnemonic-backed key" nudge desirable? That edges into NIP-41 territory — likely a separate effort.
5. **CloudKit availability / entitlement.** Requires an iCloud container + entitlement and a signed-in iCloud account; handle "not signed in" and quota/errors gracefully. Restore must work on a clean install before any account exists.
6. **Multi-account restore UX.** With N accounts each as its own iCloud record, restore is a multi-select list. Reuse the account-picker patterns from the multi-account NostrConnect work.
7. **QR of secrets.** Even an `ncryptsec` QR is a passphrase-protected secret; ensure `snapshotProtected()` and no caching/printing leaks. Default off for raw `nsec`.

## Out of scope / future work

- **HD multi-account from one seed** (`m/44'/1237'/<account>'/0/0` with incrementing account index) — one mnemonic backs up all accounts. Attractive, but changes the account model from "independent keys" to "derived keys"; revisit as its own spec.
- **NIP-41 migration/revocation** — recover from *compromise* (not just loss) by migrating to a new key. Complements backup; separate initiative.
- **FROST / key sharding** (frostr-style) — split the key into cooperating shares so no single device/blob holds it. The strongest long-term custody story; large, separate effort.
- **Option A iCloud Keychain sync** as a labeled convenience toggle — possible later, never default.

## Plan + verification

Implementation plan to be drafted (house `superpowers` plan format) after this spec is reviewed. Anticipated verification:

- Unit: NIP-49 round-trip (encrypt→`ncryptsec`→decrypt) including NFKC passphrase normalization and `key_security_byte` selection; NIP-06 derivation produces the expected pubkey for a known test vector at `m/44'/1237'/0'/0/0`; restore-from-each-source resolves to the correct npub.
- Integration/smoke (real device): generate a new (mnemonic-backed) account, complete the backup-confirmation step, delete + reinstall, restore from seed words; restore from `ncryptsec`+passphrase; enable iCloud backup, wipe, restore from iCloud; legacy raw key shows seed words disabled with the correct messaging.
- Security: confirm the working key is still `ThisDeviceOnly` and absent from device backups after the feature ships; confirm only ciphertext is written to CloudKit (inspect the record); confirm the NSE target gained no CloudKit entitlement and the signing path is unchanged.
