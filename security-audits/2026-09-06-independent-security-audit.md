# Clave — independent security audit

**Date:** 2026-09-06
**Commit audited:** `230229a` (branch `claude/clave-security-audit-9ql5ay`); the prior third-party audit covered `ce1b958`, ten commits earlier. The only code between them is the Sign-in-with-Clave `callback=` return leg, which is audited here.
**Scope:** the threat model in `SECURITY.md` — iOS app, Notification Service Extension, `Shared/` crypto, key-handling paths, NIP-46 logic, and the `relay-proxy/` Node service.
**Method:** source review only. No Xcode, simulator, or device was available, so nothing was executed and no finding is runtime-proven. Every finding cites a file and line.
**Relationship to the prior audit:** that document applied the Impeccable *native-iOS interface* rubric and scored 11/20 on accessibility, performance, theming, platform conformance, and adaptivity. That is a UI score. Its author correctly placed the four security items outside it. This audit covers only security and does not revisit the interface score.

---

## 1. Bottom line

No critical vulnerability was found. The signing core is sound in the places that matter most: incoming requests are signature-verified before dispatch, the signer never signs client-supplied bytes as an opaque blob, unpaired callers are rejected for every method except `connect`, and per-(signer, client) permission scoping is applied consistently on the authorization path.

The prior audit's four security claims all hold at source level. I would rate three of them lower than "release blocking" and one of them about right.

The more consequential gaps are ones that audit did not reach. Two stand out:

- A client paired at **Low trust — the level the UI labels "Ask for every request" — can decrypt the user's direct messages with no prompt at all.** Decryption permission is granted unconditionally at every trust level and is never mentioned on the pairing sheet.
- The push proxy hands **every registered user's public key to any relay a caller names**, and anyone with a throwaway keypair can name one.

Neither exposes the nsec. Both undermine what the product promises.

**Counts.** 30 findings confirmed by two independent reviewers each: 1 High, 6 Medium, 21 Low, 2 Informational. A further 22 candidates could not be verified before the audit run hit a spend limit; they are listed in §7 as leads, not findings, except the four I verified by hand.

---

## 2. Verdict on the prior audit's four findings

All four describe real code. My severity assessment differs because the exploit paths are narrower than the writeup implies.

| # | Prior claim | Holds? | My severity | Why it differs |
|---|---|---|---|---|
| 1 | Connection links logged as public data | Yes | **Low–Medium** | Real and worth fixing. But the leaked `secret` is the client's one-shot handshake nonce, not a Clave credential: learning it after the pairing grants nothing. The residual harm is pairing metadata in shared logs. |
| 2 | Key export fails open without device auth | Yes | **Low–Medium** | Reachable only on a device with no passcode, where the Keychain class `AfterFirstUnlockThisDeviceOnly` is already weak. Fail closed regardless. |
| 3 | Snapshot protection applied inconsistently | Yes | **Low–Medium** | Confirmed. Onboarding takes the nsec in a plain `TextField` while `AddAccountSheet` already uses `SecureField`, so the fix is a one-line consistency change. |
| 4 | Account switch binds an old subscription to the new key | Yes | **Medium** | The most substantive of the four. It is a correctness bug with a security consequence: a signing request can be silently lost, and activity is attributed to the wrong account. |

Both reviewers assigned to each claim agreed it was accurate; they split Low versus Medium on all four, which is the honest range.

The prior audit's remediation for #4 (bind pubkey, nsec, and relay plan into one immutable generation) is right, but two smaller changes fix most of the harm: restart the foreground subscription in `switchToAccount` (`Clave/AppState+AccountManager.swift:138`), and move `markEventProcessed` after a successful decrypt (`Shared/LightSigner.swift:99`).

One prior finding I could not sustain as a security issue: the root alert rotating to the next request in place (`Clave/Views/MainTabView.swift:77`). The alert's `presenting:` value binds the Approve action to the request being displayed, so a tap always approves what is on screen. It remains a legitimate accessibility finding.

---

## 3. High

### H1. Message decryption is auto-granted at every trust level, including "Ask for every request"

`Shared/ClientPermissions.swift:66` · `Shared/LightSigner.swift:379`

`defaultMethodPermissions` contains all four encrypt and decrypt methods, and every pairing path stores it unconditionally — bunker (`LightSigner.swift:239`) and nostrconnect (`ApprovalSheet.swift:935` and `:744`) alike, whatever trust the user picked. The permission check is:

```swift
case "nip04_encrypt", "nip04_decrypt", "nip44_encrypt", "nip44_decrypt":
    allowed = perms.isMethodAllowed(method)
```

and `isMethodAllowed` (`ClientPermissions.swift:155`) tests set membership only. It never reads `trustLevel`.

So a client paired at Low trust, described in the sheet as "Ask for every request" (`ApprovalSheet.swift:358`), can call `nip44_decrypt` on every kind:4 and kind:1059 event addressed to the user and receive plaintext, with no prompt on any surface. The pairing sheet lists only `sign_event` kind toggles (`ApprovalSheet.swift:401`); decryption is never disclosed at consent time. Revocation exists, but only after the fact in `ClientDetailView`.

This is the gap between what the product tells the user and what it does. Full message history is asset 3 in the threat model.

**Fix.** Derive `methodPermissions` from the trust level rather than a constant: Low prompts for every decrypt, Medium prompts once per client or grants encrypt only, Full grants all. Add an Encryption section to the approval sheet so the grant is visible before the user taps Approve. Note that NIP-44 v3 already models this correctly with per-(method, kind, scope) grants — v2 is the outlier.

---

## 4. Medium

### M1. The push proxy discloses every registered user's public key to any relay a caller names

`relay-proxy/proxy.js:553` · `relay-proxy/relayPool.js:34` · `relay-proxy/proxy.js:296`

The relay pool builds one subscription filter and sends it to every relay it is connected to:

```js
signerPubkeysProvider: () => [...new Set(storage.loadTokens().map((t) => t.pubkey))]
```

```js
function narrowFilter() {
  return { kinds: [24133], "#p": signerPubkeysProvider(), since: ... };
}
```

Relays enter that pool through `/pair-client`, which accepts up to ten caller-supplied URLs. That endpoint authenticates the caller with NIP-98 but never checks that the signer is a registered user: it simply takes `result.pubkey` from the auth event. Generating a fresh keypair costs nothing.

So anyone can mint a keypair, call `/pair-client` with `relay_urls: ["wss://attacker.example"]`, and receive a subscription listing the public key of every Clave user. Repeat with fresh keys to bypass the per-signer quotas of 5 pairs and 50 novel relays.

URLs are validated as parseable `ws:`/`wss:` only. There is no block on loopback or private ranges, so the same endpoint is a blind SSRF primitive against the proxy's own network, including the local strfry instance the README places on `localhost:7778`.

I verified this one by hand after the assigned reviewers were cut off.

**Fix.** Send each relay only the pubkeys of clients actually paired to it, not the global roster. Require the `/pair-client` signer to hold a current registration. Reject loopback, private, and link-local hosts. These are independent changes; the first alone removes the roster disclosure.

### M2. Medium trust silently signs relay-auth and HTTP-auth events

`Shared/SharedStorage.swift:166` · `Shared/ClientPermissions.swift:149`

The protected set is `[0, 3, 5, 10002, 30078]`. At Medium trust everything else is auto-signed. That includes kind 22242 (NIP-42 relay authentication) and kind 27235 (NIP-98 HTTP authentication).

The consequence is not theoretical for this codebase: Clave's own proxy authenticates with NIP-98 and checks only kind, `u`, `method`, `payload`, and age (`relay-proxy/nip98.js:36`). A Medium-trust client can ask Clave to sign a kind 27235 event with `u = https://proxy.clave.casa/unpair-client`, then present it to the proxy as the user and tear down their own push subscriptions. Kind 22242 lets the same client authenticate as the user to AUTH-gated relays, which is the barrier standing between it and the user's gift-wrapped messages. Combined with H1, that chain ends in message plaintext.

The code already treats kind 22242 signing as security-relevant: an earlier fix removed an unpaired-client exemption for exactly this reason (`Shared/LightSigner.swift:341`). The protection stops at pairing.

**Fix.** Add 22242, 27235, and 24242 to the default protected set. At minimum always prompt for a 27235 whose `u` points at the proxy. Show the `u` or relay tag in the prompt.

### M3. Signing prompts never show what is being signed

`Clave/Views/Inbox/PendingRequestDetailView.swift:431`

The approval detail view renders the kind label and the text "Encrypted request, N bytes — full content shown after approval." A comment at line 418 explains the view "can't decrypt without the nsec" — but the app process does hold the key. `LightSigner.sendRejection` (`:1058`) decrypts the very same stored `requestEventJSON` in-app, on the deny path.

So the protected-kind gate delivers "which kind" consent, not "what" consent. A user approving a kind 0 cannot see that it swaps their lightning address; approving a kind 3 cannot see it empties their follow list; approving a kind 5 cannot see which notes it deletes. The lock-screen action shows even less.

**Fix.** Decrypt in the detail view and render kind-specific summaries. `ActivitySummary` already computes follow-list diffs after signing; the same code can run before.

### M4. Attacker-chosen client name is injected line-first into approval prompts

`Clave/Views/MainTabView.swift:228` · `Shared/PendingApprovalBanner.swift:141`

The client's self-asserted `name` is stored raw from both pairing paths (`ApprovalSheet.swift:936`, `LightSigner.swift:236`). `URLComponents` percent-decoding means `%0A`, bidi overrides, and zero-width characters survive into storage. Both the root alert and the lock-screen banner build their body as `"From: \(clientLabel)"` joined with newlines, with the kind line after.

A client named `Damus\nKind 1: Short text note\n\n\n…` pushes the genuine kind line out of the visible banner. The pairing sheet is careful here — `CallerIdentity` marks self-asserted values unverified and refuses to let a name take the headline — but the signing-approval surfaces give that same string the first line with no marker.

**Fix.** Sanitize `name`, `url`, and `imageURL` at ingestion on both paths: strip control, bidi, and zero-width characters, collapse whitespace, cap length. Put the kind or method line first in both bodies. Cap `v3Scope` in the banner too.

### M5. Bunker secrets are kept in the app-group plist, not the Keychain

`Shared/SharedStorage.swift:264`

Per-signer bunker secrets are JSON-encoded into `UserDefaults` for the app group. That store is included in iCloud and Finder backups and readable by any process holding the app-group entitlement. The nsec, correctly, is not: it lives in the Keychain as `ThisDeviceOnly`.

A valid bunker secret is a bearer credential. Presenting it yields a Medium-trust pairing with full decrypt permission (H1) and no approval sheet. It rotates only after a successful pairing (`LightSigner.swift:278`), so an unused secret is valid indefinitely — and the pairing-cap rejection path returns before rotation, leaving it valid after a failed attempt.

**Fix.** Move the secrets to the shared Keychain with the same accessibility class as the nsec. Give them a TTL, generate on bunker-URI display, and rotate on cap rejection.

### M6. Text selection on the exported key bypasses the pasteboard mitigation

`Clave/Views/Settings/ExportKeySheet.swift:134`

The Copy button carefully sets `.localOnly: true` and a 120-second expiry, citing a prior audit finding. The `Text(nsec)` above it sets `.textSelection(.enabled)`. Long-press and Copy — the obvious gesture on a selectable monospaced key — writes the nsec to the general pasteboard with neither flag, syncing it to every Handoff device on the iCloud account with no expiry.

**Fix.** Remove `.textSelection(.enabled)` and leave the mitigated button as the only copy path.

---

## 5. Low

Confirmed, lower priority. Grouped by theme.

**Authorization and pairing**
- `authz-6` The bunker secret never expires, and a successful bunker pairing produces no user-visible notification at all — the NSE maps it to an empty title and body. A client can pair silently with a name of its choosing. `Shared/LightSigner.swift:278`
- `authz-7` No freshness bound on incoming requests, and the dedupe ring ages entries on the client's own `created_at`, so a captured request older than 60 seconds is replayable indefinitely. `Shared/SharedStorage.swift:612`
- `authz-8` Ghost pairing: `runSingleConnect` persists the permissions row before connecting to any relay and never rolls it back on failure or cancel, so a handshake the user saw fail can leave a working pairing. `Clave/AppState+NostrConnect.swift:173`
- `authz-5` The pending-approval queue is one global 20-entry drop-oldest ring across all accounts and clients; evicted requests get no expiry record and no rejection. `Shared/SharedStorage.swift:108`
- `authz-4` An unauthenticated flood of kind:24133 events addressed to a user fills the 200-entry activity log with decrypt failures, evicting the audit trail. `Shared/LightSigner.swift:130`

**Cryptography** — no break found; these are hardening.
- `crypto-01` `nip04Decrypt` accepts an attacker-controlled IV of any length and hands it to `CCCrypt`, which always reads 16 bytes. A short IV reads past the buffer and the over-read bytes are XORed into the returned plaintext. `Shared/LightCrypto.swift:29`
- `crypto-02` `Bech32.decode` never verifies the checksum: `polymod` exists but only `encode` uses it. A corrupted nsec decodes to different bytes instead of failing. `Shared/Bech32.swift:25`
- `crypto-03` `Data(hexString:)` accepts `+`/`-` signs and uppercase, so `verify()` admits non-canonical pubkey and signature strings that then serve as client identity. `Shared/LightEvent.swift:210`
- `crypto-04` The bunker-secret generator discards the `SecRandomCopyBytes` status; an RNG failure yields and persists an all-zero secret. Every other RNG call site in the codebase checks. `Shared/SharedStorage.swift:282`

**Secrets and data at rest**
- `secrets-5` Full signed-event JSON is retained for 200 entries in the backed-up app-group plist, including kind 22242 and 27235 auth tokens. `Shared/LightSigner.swift:585`
- `secrets-4` "Copy Recent Logs" exports every category with no filter, carrying the finding-1 deeplink line and paired relay URLs to an unrestricted pasteboard. `Clave/Views/Settings/SettingsView.swift:372`
- `secrets-3` The bunker URI copy sets an expiry but not `.localOnly`, so the secret syncs across devices. Plausibly intentional; document it or match the export sheet. `Clave/Views/Connect/BunkerURIRender.swift:247`
- `secrets-6` The onboarding stash persists the nostrconnect secret in `UserDefaults.standard`, with the TTL enforced only lazily on the next read. `Clave/OnboardingConnectStash.swift:88`
- `secrets-7` The legacy `signer-nsec` Keychain entry is deleted once any account exists, with no migration path; separately, the legacy global bunker secret is handed to whichever signer asks first. `Clave/AppState+AccountManager.swift:107`

**Entry points and consent**
- `entry-01` The `callback=` scheme filter is a blocklist, so `googlechromes://`, `firefox://open-url?url=`, `microsoft-edge:`, `x-safari-https://`, `lightning:` and similar pass through and are opened after approval. This defeats the documented host-binding guarantee for the browser case, since a browser scheme carries an arbitrary destination. `Clave/CallbackTarget.swift:59`
- `entry-03` The approval sheet and the onboarding banner fetch the caller's self-asserted image URL before the user approves anything, leaking the user's IP and an "opened" beacon to an attacker-chosen host. Post-pairing surfaces refetch on every render. `Clave/Views/Home/ApprovalSheet.swift:289`
- `entry-07` Relay URLs from the URI are unvalidated on device: no `wss` requirement, no host restriction, no count cap. The proxy caps at 10; the app does not. `Shared/NostrConnectParser.swift:142`
- `entry-09` The multi-account picker pre-selects every account, so one tap links all of the device's identities and profiles to the partner. `Clave/Views/Connect/ConnectAccountPicker.swift:384`
- `entry-10` The self-asserted `url` is rendered verbatim on post-pairing surfaces, bypassing the `CallerIdentity` rules that protect the approval sheet. `Clave/Views/Home/ClientDetailView.swift:192`

**Cross-process state**
- `background-02` `touchClient` in the NSE reads, mutates, and rewrites the whole permissions array, and appends the row when absent. It can revert a trust downgrade or resurrect a client the user just unpaired. The `NSLock` guarding these paths is per-process. `Shared/SharedStorage.swift:476`
- `background-01` The same unlocked read-modify-write pattern on `pendingRequests` can resurrect a denied request or drop a new one. `Shared/SharedStorage.swift:103`
- `background-06` Because events are marked processed before decryption, an NSE timeout drops the request permanently for 60 seconds while reporting "Signing timed out". Same root cause as prior finding 4. `ClaveNSE/NotificationService.swift:355`

---

## 6. Informational

- `background-05` `.authenticationRequired` on a notification action means *device unlocked*, not *biometric prompt*. Comments at `Clave/ClaveApp.swift:70`, `:209` and `Shared/PendingApprovalBanner.swift:178` describe it as Face ID gating and shoulder-surfing defense. On an unlocked phone no re-authentication occurs. Worth correcting, and worth considering a real `LAContext` gate for protected kinds and trust upgrades.
- `crypto-05` No known-answer vectors for NIP-44 v2 or NIP-04, and no tests for `handleRequest` permission enforcement — unpaired rejection, bunker-secret validation, protected-kind deferral. NIP-44 v3 has full spec vectors, so the newer code is better covered than the code carrying every request today.
- `secrets-8` README security-model claims that no longer match the code: the push payload is described as content-free `{relay_url, event_id}` while the NSE reads an embedded `event`; "what the push proxy sees" omits the client pubkeys and relay URLs sent via `/pair-client`.
- `supply-05` `SECURITY.md` references a `security-audits/` directory that did not exist until this file.
- `supply-06` `Clave.xcodeproj/xcuserdata/…` is tracked despite `.gitignore`, exposing a developer username.
- `supply-08` `ITSAppUsesNonExemptEncryption = false` while the app ships its own ChaCha20 and AES-CBC for content encryption. Worth a second look at the export-compliance answer.
- `background-08` The README states the NSE deploys to iOS 26.4; the project sets the NSE target to 17.6 and only the test bundles require 26.4.
- `entry-11` `createdDuringFlow` is set on the replay payload but never consumed.

---

## 7. Unverified leads

The audit ran 124 agents; 44 were cut off by a spend limit, all of them verifiers rather than finders. Four of the highest-value ones I verified by hand and promoted above (M1, plus the three below). The rest are recorded here as leads. They come from a single reviewer and have not been independently checked — treat them as starting points, not findings.

Verified by hand and confirmed:
- **Cross-account relay linkage.** `ForegroundRelaySubscription.relaySet()` (`Shared/ForegroundRelaySubscription.swift:198`) unions relay URLs across *all* accounts' clients via the unscoped `getConnectedClients()`, then subscribes with the *current* account's pubkey. A relay introduced by pairing a throwaway account receives subscriptions naming every other account, from one IP. That is exactly the linkage a multi-account signer exists to prevent. Medium.
- **Unverified profile events.** `fetchProfile` (`Clave/AppState+ProfileFetcher.swift:239`) filters by `authors` but never verifies the returned event's signature. A hostile relay can set any account's display name and avatar, and those values appear in the "Signing as" line of the approval sheet and in the multi-account connect ack. Consent-UI integrity. Medium.
- **`deleteAccount` never sends the proxy unpair.** `unpairClientWithProxy` (`Clave/AppState+ProxyClient.swift:350`) loads the nsec *inside* an async `Task`, while `deleteAccount` deletes the Keychain entry synchronously at step 3 (`Clave/AppState+AccountManager.swift:270`). The task then finds no key, the queued retry finds no key and drops the operation, so the proxy keeps the pairing rows for a deleted account. `unregisterWithProxy` gets this right — it loads the key synchronously first. Low.

Not verified — one reviewer only:
- Proxy: no signature verification on incoming kind:24133 before dispatching a push, so any relay can wake any user's device (`relay-proxy/proxy.js:542`). I confirmed the absence of a verify call; the impact rating is unverified.
- Proxy: `tokens.json` written non-atomically and treated as empty on a malformed entry; unbounded pre-auth request bodies; no rate limiting; NIP-98 events replayable within the 60-second window with no nonce cache; relay refcounts leaked on re-pair; pairing metadata in world-readable files.
- Proxy: a reviewer cited a `ws` advisory with a 2026 identifier. The lockfile pins `ws@8.20.1`, which is past the known `ws` denial-of-service advisory affecting versions below 8.17.1. **I could not verify the claimed advisory exists.** Check it against the GitHub advisory database before acting on it.
- App: relay frames parsed on the main actor; sockets left half-alive across `stop()`; `LightRelay` never invalidating its `URLSession`; the lock-screen banner never naming the signing account; non-atomic bunker connect across the two processes; per-pubkey residue left in the app group after `deleteAccount`; SwiftPM requirements being `upToNextMajor` rather than exact.

---

## 8. Checked and found sound

Worth recording, because these are the places a signer usually fails.

- **No signature oracle.** `signUnsignedEvent` (`Shared/LightEvent.swift:95`) parses only kind, content, tags, and `created_at`, recomputes the id from canonical serialization, and signs with the signer's own pubkey. Client-supplied `id`, `pubkey`, and `sig` are ignored. A client cannot get an arbitrary 32-byte digest signed.
- **No parser differential.** The kind used for the permission check and the kind that gets signed are parsed from the same string by the same parser (`LightSigner.swift:extractEventKind` and `LightEvent.signUnsignedEvent`), so there is no way to show one kind to the gate and sign another.
- **Requests are verified before dispatch.** `LightEvent.verify` recomputes the id and checks the BIP-340 signature before dedupe and before decryption (`LightSigner.swift:76`), and forged events are dropped silently rather than banner-spamming the user.
- **Unpaired callers are rejected** for every method except `connect`, including kind 22242, with the history of that decision documented at `LightSigner.swift:341`.
- **Permission lookups are signer-scoped** on the authorization path. The remaining unscoped `getClientPermissions(for:)` callers are display-only.
- **The NSE does not trust the push payload for authorization.** It derives the pubkey from the loaded key and compares (`ClaveNSE/NotificationService.swift:178`), so a compromised proxy cannot redirect signing to a different account.
- **NIP-44 v2 constant-time MAC comparison** and MAC-before-decrypt ordering are correct (`Shared/LightCrypto.swift:249`).
- **No TLS override or ATS exception** anywhere in the project.
- **The approval alert's Approve button is bound to the request being displayed** via the `presenting:` value, so in-place rotation cannot cause a tap to approve an unseen request.
- **Pasteboard handling for the exported key** sets local-only and an expiry — the mitigation exists and works; only the selection path (M6) goes around it.

---

## 9. Suggested order

1. **H1** — derive decrypt permission from trust level, and disclose it on the pairing sheet. This is the one that contradicts what the UI promises.
2. **M1** — stop sending the global pubkey roster to caller-supplied relays; require registration for `/pair-client`; block private hosts.
3. **M2** — add the auth kinds to the protected set.
4. **Prior finding 4** — restart the subscription on account switch; mark events processed only after a terminal outcome. This also closes `background-06`.
5. **M5, M6, prior findings 1–3** — secret-handling hygiene; each is small and local.
6. **M3, M4** — approval-surface integrity: show what is being signed, sanitize what the client asserts.
7. **Cross-process writes** (`background-01`, `background-02`) — these need a real cross-process lock, so scope the work before starting.
8. **Low crypto hardening** (`crypto-01` through `crypto-04`) — cheap, and `crypto-01` and `crypto-04` are one-line guards.

Two things worth doing alongside the fixes, given how much of this audit rests on unexecuted code: add NIP-44 v2 known-answer vectors, and add offline tests for the enforcement branches in `handleRequest`. The v3 path already has spec vectors; the v2 path carries every request today and has none.

---

## 10. Limits of this audit

- Source review only. Nothing was built, run, or tested on a device or simulator. Runtime behavior — actual snapshot timing, `OSLogStore` redaction of private interpolations, whether `CCCrypt` faults or silently over-reads on a short IV — is unconfirmed.
- 44 of 124 review agents were cut off by a spend limit. The network, multi-account, and proxy lanes lost most of their verification passes. §7 records what that leaves unverified.
- The completeness critic never ran, so there is no independent assessment of what all lanes missed together.
- Third-party dependency advisories were not checked against a live database.
- `relay-proxy/` was read but never executed, and no live instance was tested. `SECURITY.md` forbids testing against production, which is the right rule.
