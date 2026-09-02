# Sign in with Clave — partner SDK + new-user onboarding flow

_2026-09-02 — design spec for the "Sign in with Clave" plugin: a static partner SDK plus small
diffs to shipped machinery that let any Nostr app offer one-tap Clave login, including the
brand-new-user path a partner app (Conduit) requested: install Clave from inside the partner app,
create or import an identity, and return with a working NIP-46 session. Spec of record for work
tracked in clave-casa `BACKLOG.md` § "Sign in with Clave"._

## Context

The concept has been accumulating across both repos since May. Shipped building blocks:

- **Universal Link handoff** (2026-05-03): partners wrap a `nostrconnect://` URI as
  `https://clave.casa/connect/?uri=<enc>`; AASA (scoped to exactly `/connect?uri=*` + slash
  variant, appID `944AF56S27.dev.nostr.Clave`) routes it into Clave, bypassing the
  `nostrconnect://` scheme squat. Fallback page renders QR + install links when Clave is absent.
- **`clave-casa/docs/integrations.md`** — the plugin v0: a 5-line "Connect with Clave" button
  recipe (vanilla/React/Svelte/Vue).
- **Protocol extensions**: `accounts=multi` (build ≥85 — integrations.md says "build 80", but
  pbxproj history shows the landing build was 85; fix that doc in the Phase-1 doc pass) and the
  bunker-connect client-metadata 4th param `{name,url,image}` (build ~100) — a partner session
  can carry its own name/icon.
- **Lock-screen Face-ID Approve** (`PENDING_SIGNING_REQUEST` category, `ClaveApp.swift`): the
  Approve action deliberately omits `.foreground` and signs in the background, so post-pairing
  requests are approved from a banner **over the foregrounded partner app** — no app switch.
  Confirmed platform-valid (UNUserNotificationCenter contract, stable through iOS 17+).
  This is the "smooth as hell" ingredient, and it is currently undocumented for partners.

Planned but unshipped (absorbed or superseded by this spec): the BACKLOG "Clave iOS new-account
flow integration" (fresh account → clave.casa editor handoff), ecosystem outreach PRs (POWR
first), `static/brand/` button assets, the Discover tab (stub), and the iOS publish side of
`session_terminated`.

### Why the new-user flow is broken today — four specific breaks

1. **`Shared/DeeplinkRouter.swift:56`** — `accountCount <= 0` returns `.ignore`; a brand-new
   user deep-linked into Clave has the partner's connect URI silently dropped. (The
   `ConnectAccountPicker.shouldAutoSkip` doc comment records the *intent* — "the caller should
   route to onboarding" — that was never implemented.)
2. **No deferred deep link**: nothing survives the App Store round trip. The `/connect`
   fallback page keeps the inbound URI in component memory only.
3. **No profile creation**: iOS has no kind:0 publish path anywhere; a freshly generated
   identity is a ghost npub (no name, no avatar, no NIP-65).
4. **No return leg**: `NostrConnectParser` has no callback/redirect param; the user swipes back
   manually. Same-device nostrconnect is brittle at ack time — the partner's WebSocket freezes
   ~5–10s after backgrounding, and kind:24133 is in the ephemeral range, so the one-shot connect
   ack is likely gone by the time the socket revives.

Two facts make the fix far cheaper than it looks:

- `HomeView` already owns a `pendingNostrconnectURI` → ApprovalSheet replay path
  (`HomeView.swift:142`), and `ContentView` flips from `OnboardingView` to `MainTabView` the
  instant `currentAccount` is set (synchronously inside `addAccount`,
  `AppState+AccountManager.swift`). Stash-and-replay through onboarding is therefore a small
  routing diff, not new UI plumbing. (`OnboardingView`'s step-2 "Key Secured" screen is
  unreachable dead code for the same reason — do not build on it.)
- The reserved `clave://` scheme (registered, zero handlers) is exactly what partner-side
  install detection needs: `canOpenURL("clave://…")` works once partners declare
  `LSApplicationQueriesSchemes`; Universal Links are not probeable.

## Protocol direction: nostrconnect establishes, then the directions converge

**The sign-in handshake is the `nostrconnect://` flow (client-initiated), not bunker.** A
sign-in button must be partner-initiated, and bunker cannot be: bunker URIs are exported by a
manual user action in Clave, the secret is single-use and rotates on redemption
(`LightSigner.swift`), and there is deliberately no API for a partner to mint one — exposing
bunker issuance to partners would let them create pairing material out-of-band and is rejected
here as a non-goal.

After the handshake the distinction disappears: every subsequent RPC is a kind:24133 event over
the paired relays, caught by the proxy's primary subscription on `wss://relay.powr.build`,
pushed via APNs, and auto-signed or surfaced for lock-screen approval by the NSE — the identical
runtime a bunker session gets. The FAQ's current "start from Clave, not the other app" guidance
for same-device pairing exists only because of the ack-time WebSocket freeze; the resume probe +
idempotent re-ack window below fix that specific weakness, which is what makes partner-initiated
nostrconnect reliable enough to be the button. Partners MUST include `wss://relay.powr.build`
in the URI relay set (proxy wake path) and SHOULD send `name`/`url`/`image` metadata so
ApprovalSheet and the onboarding banner can show who is asking.

## Goals

- **One-tap sign-in for existing Clave users** from partner iOS apps and web apps, ending in a
  live NIP-46 session, with the lock-screen Approve leg documented as the post-pairing UX.
- **The Conduit flow**: brand-new user (no Clave, no identity) installs Clave without leaving
  the partner app, creates **or imports** a key, and returns with a working session.
- **A partner SDK that is boring to adopt**: static `sdk.js` on clave.casa + npm, a documented
  Swift recipe (package later), button assets in `static/brand/`, and an integrations.md
  rewrite that leads with lock-screen approve and the rust-nostr ≤0.44.2 secret-echo warning.
- **Dissolve, don't solve, the deferred-deep-link problem**: the SDK minted the URI, so it
  re-mints a fresh secret on every retry/foreground. On the SDK path nothing must survive the
  install trip; the `/connect` fallback page is the non-SDK degradation and stashes tab-locally.
- **Keep the privacy promises**: no broker service, no attribution, no analytics, static-only
  clave.casa, everything device-local.

## Non-goals (all four design lenses independently rejected these)

- **No App Clip** (no target exists; ties to App Store availability; adds Apple-side invocation
  analytics; the re-mint approach makes context-through-install unnecessary). Revisit only if
  funnel drop-off is measured and material.
- **No clipboard/pasteboard deferred deep link** (iOS 16+ paste prompt; tracking-vector optics).
- **No server-side broker/attribution endpoint** (breaks adapter-static + zero-analytics).
- **No AASA scope broadening** (`/connect?uri=*` stays the only Universal Link surface; the
  scoping note in the AASA file stands).
- **No partner-mintable bunker URIs** (see direction section above).
- **No signer-side "ack echo loop"** (a 20–30s background-task timing race; strictly dominated
  by the client-initiated recovery below).
- **No relay-stored-ack assumption** ("poll for the missed ack with a since filter") until the
  week-1 empirical test says otherwise — kind:24133 is in the ephemeral range and conforming
  relays don't store it.

## The flows

### A. Existing Clave user, partner iOS app

1. Tap "Sign in with Clave". SDK builds a `nostrconnect://` URI (fresh client keypair + secret,
   `relay=wss://relay.powr.build` + partner relays, `name`/`url`/`image`, optional
   `callback=`), persists the client keypair, opens the Universal Link.
2. Clave: 1 account → ApprovalSheet (already renders caller branding); 2+ → account picker.
3. Approve → handshake in the existing `UIBackgroundTask` → `callback=` opens the partner app
   (foreground approvals only; `callback=` is Phase 2 — in Phase 1 the user swipes back).
4. On foreground the SDK reconnects and, if no ack was caught, sends the **resume probe**
   (below). Session live. All later signatures: lock-screen Approve over the partner app.

### B. Existing Clave user, partner web app

- Desktop: SDK renders the Universal Link as a QR; cross-device nostrconnect is already solid
  (the page's socket never froze). Mobile Safari: real `<a target="_self">` to the Universal
  Link; on `visibilitychange` back, reconnect + resume probe.

### C. Brand-new user in the partner app (the Conduit ask)

1. Tap "Sign in with Clave" → SDK probes `canOpenURL("clave://x")`. Not installed →
   **`SKOverlay.AppConfiguration`** presents Clave's App Store sheet *inside the partner app*
   (per Apple's documented SKOverlay contract — native apps only, not invocable from Safari;
   on-device confirmation is week-1 test 3). EU storefront (`SKStorefront` check) →
   TestFlight/web fallback until the listing is live there.
2. Install completes; user dismisses the overlay — they never left the partner app. On next
   foreground the SDK **re-mints a fresh URI** — new secret, same persisted client keypair
   (protects the 5-clients-per-account cap) — and opens the Universal Link, *regardless of the
   `canOpenURL` probe result* (the probe is an optimization; whether it flips to true
   immediately post-install without a partner relaunch is part of week-1 test 3). No state
   needed to survive the install: the partner app is the durable anchor.
3. Clave cold-launches with 0 accounts. `DeeplinkRouter` returns **`.stashForOnboarding`**
   (replacing `.ignore`); AppState persists the parsed URI (UserDefaults, scrubbed after
   replay; TTL: Phase 1 always 10 min, URI `expiry=` once Phase 2 lands); `OnboardingView`
   shows a caller banner — "*Conduit* wants to connect — create or import your key to
   continue" — under the same domain-first + unverified-metadata rendering rules as
   ApprovalSheet (brand-new users are the most phishable audience). Stash rules: **single-slot,
   last-writer-wins** — a newer connect URI replaces and scrubs an older one (secrets are
   single-use; the loser's partner retry covers it). An expired stash is scrubbed *without*
   replay at promotion time, and the banner is removed (or swapped to "Return to *Conduit* and
   tap Sign in again") on expiry.
4. User taps **Generate New Key** *or pastes an nsec into* **Import Existing Key** (both
   already exist on onboarding step 1). Either way `addAccount` sets `currentAccount`,
   ContentView flips to MainTabView, and the stash is promoted into `pendingNostrconnectURI` —
   the verified HomeView replay presents ApprovalSheet with the partner's branding. The replay
   always pairs the account that triggered promotion (`currentAccount` as set by that
   `addAccount`); it never re-enters the 2+-accounts picker decision, regardless of how many
   accounts exist by replay time.
5. Approve → callback (Phase 2) or swipe back → SDK resume probe → live session.
6. **Profile leg, gated by how the key arrived** (see below).
7. Degraded path (partner app killed during install, secret expired, user dawdled): the SDK
   treats ack-timeout as *retry, not error* — the second tap re-mints and is now the fast
   existing-user path (~10s). Idempotent retry is the designed failure mode.

### The imported-nsec branch (data-integrity rule)

Import changes nothing mechanically — the stash promotes on `currentAccount != nil` regardless
of generate vs import — but it inverts the profile leg:

- **Generated in this flow** → the ApprovalSheet MAY offer the pre-consented *signup write set*
  ("Let Conduit set up your profile (kind 0) and relay list (kind 10002)") and the partner —
  which knows the merchant's name and logo — publishes them through the fresh session. The
  user types nothing; Clave builds no native profile UI in v1.
- **Imported** → the write-set consent is **never offered**. An imported identity very likely
  has an existing kind:0/kind:10002 somewhere, and a partner publish would clobber it — the
  exact hazard class as the clave.casa kind:0 wipe hotfix (clave-casa PR #1). kind:0/3/10002
  remain protected kinds; any partner write prompts individually.
- **SDK contract (both branches)**: after session establishment, *fetch kind:0 first*; only
  offer profile setup when none is found; merge-don't-replace when writing over an existing
  event; tolerate profile-less pubkeys indefinitely.

Clave can gate this precisely because `addAccount` knows the creation source. Normatively:
`createdDuringFlow` is a Bool on the promoted `pendingNostrconnectURI` payload, **not persisted
independently** — `addAccount` sets it true at promotion time iff the creation source is the
onboarding Generate path (false for import and for every non-onboarding route), and
ApprovalSheet reads it from the in-memory replay object. It dies with the replay: on an SDK
retry after a failed first replay, write-set consent is NOT offered (accepted loss — the
partner falls back to individual protected-kind prompts per the fetch-kind:0-first contract).

## Component changes

### Clave iOS

| Change | Where | Size |
|---|---|---|
| `.stashForOnboarding` outcome replaces the 0-account `.ignore`; parse `clave://connect?uri=` (first handler for the reserved scheme) | `Shared/DeeplinkRouter.swift` + `DeeplinkRouterTests` | S |
| Persist stash; promote into `pendingNostrconnectURI` when `currentAccount` becomes non-nil; scrub after replay | `AppState.swift`, `AppState+NostrConnect.swift` | S |
| Caller banner on onboarding step 1 ("create or import your key to continue") — same domain-first + unverified-metadata rules as ApprovalSheet | `OnboardingView.swift` | S |
| Domain-first ApprovalSheet rendering: registrable domain largest; self-asserted name/icon below with "unverified" treatment; short client-pubkey fingerprint | `ApprovalSheet.swift` | S |
| `callback=` support: display target in ApprovalSheet; open only after foreground approval; https callbacks should match the metadata `url` registrable domain; never on denial; never from lock-screen signing | `NostrConnectParser.swift`, `ApprovalSheet.swift` | M |
| Idempotent connect **re-ack window**: a connect re-sent with identical client pubkey + secret within ~10 min of successful pairing gets a silent duplicate ack (already-paired-only; exact match; no new prompt). Triggers only on same-URI redelivery — the `/connect` fallback page's stashed-URI "Open Clave" re-fire, OS redelivery of the same link, and non-SDK clients that re-send connect on reconnect. SDK clients never hit it (fresh secret per retry); their recovery is the resume probe alone | `LightSigner.swift` (+ NSE path) | M |
| Signup write-set consent, gated on `createdDuringFlow`. The grant is **one-shot and bounded**: it authorizes at most one kind:0 and one kind:10002 publish within ~10 min of pairing; afterwards both kinds revert to protected/individual prompts for this session like any other | `ApprovalSheet.swift` | M |
| `session_terminated` publish on unpair/delete (web receiver already shipped) | `LightSigner.swift` / unpair paths | M |

### clave.casa

- `/connect` fallback hardening: sessionStorage stash of the inbound URI (documented, tab-scoped
  relaxation of memory-only — survives the App Store round trip, never leaves the device),
  parse + show caller `name` domain-first, persistent "Installed? Open Clave"
  `clave://connect?uri=` button (same-domain Universal Links deliberately don't fire, and JS
  can't re-fire one), Smart App Banner meta with `app-argument` templated before parse (it
  delivers only when installed — i.e., it is the *post-install* OPEN affordance, not a
  through-install channel), platform detection for the install panel. Stale re-fire handling:
  the page drops its stash after one re-fire; a re-fired URI whose secret was already redeemed
  is absorbed by the re-ack window, and an otherwise-dead one surfaces Clave's non-scary "This
  request expired — return to *Partner* and tap Sign in again" copy instead of a failure alert.
- `static/sdk/clave-connect.js` (versioned, immutable paths via `_headers`, published SRI
  hashes, connect origin hardcoded to `https://clave.casa` — never partner-configurable) +
  npm mirror. Core extracted from POWR's vendored ~300-line NIP-46 client. (Scope note:
  rust-nostr ≤0.44.2's echoed-secret bug breaks its *bunker://* connect path; its nostrconnect
  path reportedly works — see `docs/nip46-compatibility.md`. The vendored core still spares
  rust-nostr partners the accumulate-window and two-stage-approval quirks.)
- `static/brand/`: the button assets integrations.md has promised since May.
- `docs/integrations.md` rewrite: lock-screen Approve as the headline post-pairing UX; the
  resume-probe/re-ack contract; retry-not-error semantics; keypair persistence; fetch-kind:0-
  first profile rule; never hardcode `proxy.clave.casa` (self-hosted proxy override exists);
  `LSApplicationQueriesSchemes` + SKOverlay Swift recipe for native partners.

### SDK behavioral contract (documentation-level, v1)

1. Persist the client keypair across retries; re-mint only the secret.
2. On foreground/`visibilitychange`: reconnect, then **resume probe** — send `get_public_key`
   with the session keypair. Pairing was recorded signer-side during the background handshake,
   so the probe confirms the session even when the ack was lost; it needs no relay storage of
   ephemerals and no timing window, and it is **prompt-free**: `get_public_key` is always
   allowed for paired clients and never prompts (`LightSigner.swift:397-402`) — guard that
   invariant in week-1 test 2. The signer-side re-ack window is the belt to these braces for
   non-SDK/same-URI-redelivery cases; SDK clients (fresh secret per retry) rely on the probe.
3. Ack/probe timeout → show "Tap Sign in again"; never surface a scary error for the retry case.
4. Respect caps (4 accounts/device, 5 clients/account — proxy 409 `pairing_limit`) with
   funnel-friendly copy.

## Protocol extensions (Phase-2 NIP drafts; ship first, spec after, per house practice)

- `callback=` (with the anti-phishing rules above) — the auto-return leg.
- `expiry=` — client-declared secret validity long enough for onboarding.
- `flow=signup|login` — pure UX hint (banner copy, write-set eligibility).
- Idempotent connect re-ack — the NIP-46 erratum every mobile signer needs.
- Formalize the two shipped extensions (metadata 4th param, `accounts=multi`) and
  `session_terminated`.
- All optional/ignorable, specced signer-agnostically, so this degrades into "Sign in with
  Nostr — best on Clave" rather than lock-in.

## Week-1 empirical tests (gate promises on these)

1. Does `wss://relay.powr.build` store kind:24133 at all? (Decides how much weight re-ack vs.
   resume probe must carry.)
2. On-device: `clave://connect?uri=` cold-launch → stash → generate/import → replay → approve,
   including partner-app-killed-during-install; regression-check that `get_public_key` from the
   fresh pairing signs with no prompt (the resume probe depends on it).
3. SKOverlay from a scratch partner app + `canOpenURL` detection, including whether the probe
   flips to true immediately post-install without relaunching the partner app; EU-storefront
   fallback.
4. Smart App Banner OPEN-with-`app-argument` behavior on the real fallback page.

## Risks

- **Proxy scale**: one Node process, file-backed JSON re-read per op, co-located with
  relay.powr.build (one box, one failure domain). Eric pushing all merchants at Clave lands
  here first; harden before any co-marketed launch (storage, rate limits, at minimum
  monitoring + restart hygiene).
- **Protected-kind friction**: kind:0/10002 prompts are a *feature* for imported identities;
  the write-set consent for generated ones must stay explicit, unchecked-by-default is the
  safer opening position.
- **EU gap**: App Store listing not live in EU; TestFlight fallback expires builds every 90
  days. SKOverlay path must branch on storefront.
- **Outreach constraints** stand: no ship-date promises, no "works with every client" claims.

## Phasing

| Phase | Scope |
|---|---|
| **1 (weeks 1–2) — the Conduit unlock** | DeeplinkRouter stash + `clave://connect` handler + replay; onboarding banner; ApprovalSheet domain-first; `/connect` hardening; `sdk.js` v0 + brand assets; integrations.md rewrite (lock-screen approve, rust-nostr warning); week-1 empirical tests |
| **2 (weeks 3–8) — smooth + robust** | `callback=` + `expiry=` + `flow=`; re-ack window; signup write-set consent (generated-only gate); SwiftPM recipe → package with SKOverlay funnel; `session_terminated` iOS; Discover tab partner list; NIP drafts |
| **Later** | domain-verified caller badge (well-known JSON at the metadata `url` origin listing authorized client pubkeys); proxy hardening; RN wrapper (pending Conduit/POWR stack answer) |

## Open questions (for Eric / Conduit)

1. Which stack does Conduit sign with — rust-nostr (inherits the ≤0.44.2 bunker-connect bug),
   nostr-tools, or the in-house replacement for the NDK they're phasing out?
2. Native iOS app, web app, or both? (Decides sdk.js vs SwiftPM priority.)
3. EU merchants? (Decides how much the TestFlight fallback matters.)
4. Will Conduit publish merchant kind:0/10002 through the session (preferred), or does the
   clave.casa/edit#bunker= handoff need to be the v1 profile path?
