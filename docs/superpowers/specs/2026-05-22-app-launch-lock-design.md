# App-Launch Lock — biometric/passcode gate + privacy overlay

_2026-05-22 — design spec for Tier 2 of the Amber-parity gap analysis. Today Clave authenticates the user only for two actions (revealing the key, and approving from the notification banner); the app itself opens with no gate, so an unlocked, unattended phone exposes accounts, activity, paired clients, and the ability to pair new clients and approve in-app. This spec adds an optional Face ID / Touch ID / passcode lock on launch and resume, gates the in-app approval sheet, and blurs the app-switcher snapshot. It is a UI-level access gate, not a change to at-rest key encryption._

## Context

Clave's current use of `LocalAuthentication` is narrow and correct as far as it goes:

- **Key reveal/export** is gated by `LAContext` — biometrics with passcode fallback (`ExportKeySheet.swift:101-130`).
- **Notification-banner Approve** carries `UNNotificationAction` option `.authenticationRequired` (`ClaveApp.swift:79`), so iOS demands Face ID before dispatching the background approve — shoulder-surfing defense for the "approve without opening the app" path.

What's **not** gated:

- **Opening the app.** There is no launch/resume authentication. `MainTabView` observes `scenePhase` only for refresh logic (`MainTabView.swift:52`), not for an auth gate or privacy overlay.
- **The in-app `ApprovalSheet`.** Approving a signing request from inside the app (as opposed to the notification action) requires no biometric. (Grep confirms no `LAContext`/`evaluatePolicy` in `ApprovalSheet.swift` or `AppState+PendingApprovalCoordinator.swift`.)
- **The app-switcher snapshot.** Only `ExportKeySheet` uses `snapshotProtected()`; the rest of the app (account list, activity, paired clients) is captured in the iOS app-switcher thumbnail.

Net exposure: someone holding an unlocked phone can open Clave, enumerate the user's accounts and npubs, read the activity log, see and revoke paired clients, pair new clients, and approve queued requests in-app — none of which requires authentication. Amber gates access to the app behind device authentication. This is a cheap, high-trust-signal gap to close.

## Goals

- **Optional app-launch lock.** When enabled, require Face ID / Touch ID (with device-passcode fallback) before the UI is usable, on cold launch and on return-to-foreground after a configurable timeout.
- **Gate the in-app approval sheet.** Bring the in-app `ApprovalSheet` to parity with the notification-action path: require authentication immediately before a signing approval is committed, regardless of lock setting.
- **Privacy overlay on backgrounding.** Cover the UI with an opaque overlay when the app goes `.inactive`/`.background` so the app-switcher thumbnail and quick glances don't leak account/activity content. Extend the existing `snapshotProtected()` approach app-wide.
- **Sensible configuration.** A Settings toggle for the launch lock plus an auto-lock timeout (e.g. Immediately / After 1 min / After 5 min). Default chosen in "Open questions."
- **Never break background signing.** The NSE runs in a separate process and must keep signing on push while the main app is locked. The lock is a main-app UI gate only.

## Non-goals

- **Not at-rest encryption of the Keychain by a user PIN.** The key's at-rest protection is the iOS Secure Enclave / Keychain (`ThisDeviceOnly`, after-first-unlock). This lock is an *access gate on the UI*, not a second encryption layer. (Encrypting the key under a user passphrase is the separate Tier 1 backup feature.) We will say this plainly so the threat model isn't oversold.
- **Not a replacement for the device passcode.** If the device has no passcode and no enrolled biometrics, iOS can't authenticate the user; the lock can't be enforced and the toggle is disabled with an explanatory note.
- **Not a per-tap PIN on every action.** Beyond launch/resume and the approval commit, we don't gate ordinary navigation.
- **No custom in-app PIN entry UI.** We use the system `LocalAuthentication` sheet (biometrics → device passcode fallback), not a bespoke numeric PIN, to avoid inventing credential storage.

## Design

### Lock state and gating

A `lockState` lives on `AppState` (`locked` / `unlocked`), driven by a small coordinator:

- **Cold launch:** if the lock setting is on, start `locked`; present the lock screen over the tab view; call `LAContext.evaluatePolicy` on appear.
- **Resume:** observe `scenePhase` in the root view (the hook already exists at `MainTabView.swift:52`). On `.background`/`.inactive`, record a timestamp and show the privacy overlay. On `.active`, if `(now - backgroundedAt) >= timeout`, set `locked` and re-authenticate.
- **Policy:** `LAContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` if available, else `.deviceOwnerAuthentication` (passcode) — mirroring the proven logic already in `ExportKeySheet.swift:105-108`. Factor that selection into a shared helper so both call sites agree.

### Lock screen

A minimal full-screen view (app glyph + "Unlock Clave" + a "Unlock" button that re-triggers auth if the first attempt is dismissed/fails). No app content renders behind it. Reuse `snapshotProtected()` so the lock screen itself is what the switcher captures when locked.

### In-app approval gate

Immediately before `ApprovalSheet` commits an approval (the in-app counterpart to the notification action's `.authenticationRequired`), run `evaluatePolicy` with reason "Authenticate to approve this signing request." On success, proceed with the existing approve path; on failure, remain on the sheet. This is independent of the launch-lock toggle — approving as the user always proves it's the user. (Deny needs no auth, matching the notification action where only Approve is `.authenticationRequired`.)

### Privacy overlay

On `scenePhase != .active`, overlay an opaque cover (app glyph on the brand background) above all content. This is distinct from the lock: it shows even with the lock disabled, purely to keep the switcher thumbnail clean. When the lock is enabled, returning past the timeout transitions overlay → lock screen.

### What stays untouched

- **NSE / push signing.** No NSE changes. While the main app is locked, a push still wakes the NSE, which signs from the Keychain as today. The notification-action Approve keeps its own `.authenticationRequired` gate. The lock never blocks the signing path — it only gates the main-app UI.
- **Existing key-reveal gate.** `ExportKeySheet`'s biometric gate stays; with the launch lock on, the user may authenticate twice (launch + reveal), which is acceptable for the most sensitive action.

## Security model

- **What this adds:** defense against an attacker with physical access to an *unlocked* device — they can no longer open Clave to read accounts/activity, manage pairings, or approve in-app without passing biometrics/passcode.
- **What this does NOT add:** protection of the key at rest (that's the Keychain/Secure Enclave) or against a determined attacker who already controls the device's biometric/passcode. The lock is a UI gate; we will not imply it encrypts anything.
- **Interaction with backup (Tier 1):** combined, the story is strong — key encrypted for backup (Tier 1) *and* the app gated behind device auth (Tier 2). They're independent and ship independently.

## Risks / open questions

1. **Default on or off?** On-by-default maximizes safety and matches the "serious custody app" posture, at some first-run friction. Recommendation: **on by default when the device has biometrics/passcode available**, with timeout "After 1 minute" so quick app-switches during pairing don't re-prompt. Confirm with product.
2. **Auth churn during pairing.** Pairing often bounces between Clave and another app/QR. A too-aggressive timeout causes repeated prompts. The 1-minute default and treating `.inactive` (e.g. control center) differently from `.background` mitigate this.
3. **No-biometrics/no-passcode devices.** Disable the toggle with a note pointing the user to set a device passcode. Don't fake a lock we can't enforce.
4. **Failed/cancelled auth loop.** Provide an explicit "Unlock" retry button rather than auto-retrying, to avoid a Face-ID fail loop.
5. **Accessibility.** Ensure the lock and overlay don't trap VoiceOver users; the retry button must be reachable.
6. **Does the in-app approval gate belong in Tier 2 or with approvals work?** It's small and thematically "authenticate the user," so it ships here, but it's separable if scope needs trimming.

## Out of scope / future work

- Custom numeric PIN (independent of device passcode) for users who don't want to expose the device passcode to the app flow.
- Per-client "require auth to approve" overrides layered on the trust levels.
- Duress/decoy unlock. Not justified by current threat model.

## Plan + verification

Implementation plan to follow in the house `superpowers` plan format after review. Anticipated verification:

- Unit: timeout/lock-state transition logic (pure function over `(scenePhase, backgroundedAt, now, timeout, setting)` → `locked|unlocked`); policy-selection helper picks biometrics-else-passcode.
- Smoke (real device): enable lock → background past timeout → foreground prompts auth; cold launch prompts auth; quick switch under timeout does **not** prompt; in-app approve prompts auth and commits on success / stays on failure; app-switcher thumbnail shows the overlay, not account content; **with the app locked, a push still signs via the NSE** (the critical non-regression); toggle disabled on a device with no passcode/biometrics.
