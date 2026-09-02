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
- ~~**No relay-stored-ack assumption** ("poll for the missed ack with a since filter") until the
  week-1 empirical test says otherwise — kind:24133 is in the ephemeral range and conforming
  relays don't store it.~~ **Updated 2026-09-02:** the week-1 test said otherwise —
  `relay.powr.build` (and `relay.damus.io`) **do** store and re-serve kind:24133 to a
  since-filter. Relay replay is now an *additional* recovery rung (see the recovery ladder),
  not a rejected approach. It stays a bonus rung, not a load-bearing MUST: a partner's relay
  set may include conforming ephemeral relays, so re-ack + resume probe still carry the design.

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
7. Degraded path: the SDK treats ack-timeout as *retry, not error*, per the recovery ladder
   (below). Attempt still pending → the second tap re-fires the SAME URI and, if the pairing
   actually completed, Clave's re-ack window answers silently with no second approval; window
   expired, denied, or partner killed during install → re-mint, clean fast existing-user path
   (~10s). Idempotent retry is the designed failure mode.

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
| Idempotent connect **re-ack window**: a connect re-sent with identical client pubkey + secret within ~10 min of successful pairing gets a silent duplicate ack (already-paired-only; exact match; no new prompt). Triggers on same-URI redelivery: the SDK's own re-fire of a still-pending attempt (recovery ladder rung 2 — the fix for ack-never-received, which the resume probe cannot bootstrap), the `/connect` fallback page's stashed-URI "Open Clave" re-fire, OS redelivery of the same link, and non-SDK clients that re-send connect on reconnect | `LightSigner.swift` (+ NSE path) | M |
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

1. Persist the client keypair across attempts. While an attempt is **pending** (no ack yet,
   inside the ~10-min re-ack window) retain its secret; re-mint a fresh secret only after
   denial, window expiry, or session establishment.
2. On foreground/`visibilitychange`: reconnect, then **resume probe** — send `get_public_key`
   with the session keypair. Pairing was recorded signer-side during the background handshake,
   so the probe confirms the session even when the ack was lost; it needs no relay storage of
   ephemerals and no timing window, and it is **prompt-free**: `get_public_key` is always
   allowed for paired clients and never prompts (`LightSigner.swift:397-402`) — guard that
   invariant in week-1 test 2. **Bootstrap limitation:** the probe must be addressed to the
   signer pubkey, which the client only learns *from an ack* (the nostrconnect URI carries
   only the client's pubkey). It therefore confirms/repairs a session that acked at least
   once; it cannot bootstrap an ack-never-received handshake — that case is rung 2 below.
3. Ack/probe timeout → show "Tap Sign in again"; never surface a scary error for the retry case.
4. Respect caps (4 accounts/device, 5 clients/account — proxy 409 `pairing_limit`) with
   funnel-friendly copy.

### Same-device handshake recovery ladder

The WebSocket freeze threatens exactly one message — the connect ack (published after
human-speed approval, i.e. past the partner socket's ~5–10s post-backgrounding grace). Recovery,
in order:

1. **Catch the ack live** — cross-device always; same-device when approval lands inside the
   grace window or the socket revives during Clave's ~15s listen / 3-attempt publish window.
2. **Ack never received, attempt still pending** → the user's next Sign-in tap **re-fires the
   SAME URI** (same secret — see contract item 1). Already-paired → Clave silently re-acks
   ~1–2s after launch via the re-ack window — inside the *fresh* backgrounding grace this time,
   because there is no approval sheet to read — then callback (Phase 2) or swipe-back.
   Never-paired → normal ApprovalSheet. Native SDKs may open the Universal Link
   programmatically but should keep the re-fire behind a user gesture. Cold-launch →
   re-ack-publish latency vs. the grace window is a week-1 test-2 measurement.
3. **Window expired or denied** → re-mint a fresh secret; clean new attempt (the fast
   existing-user path).

**Bonus rung (added 2026-09-02 after week-1 test 1): relay replay.** Because `relay.powr.build`
was empirically shown to retain kind:24133 and re-serve it to a `since` filter, an SDK that
missed the live ack can also recover it by re-subscribing with `since ≈ handshake_start` on the
relays known to store it — no re-fire, no user tap. This slots between rungs 1 and 2 when the
paired relay is `relay.powr.build`/`relay.damus.io`. It is opportunistic only: it must not be
the sole recovery path (a partner relay set may be all-ephemeral), and it cannot bootstrap an
ack-never-received handshake any better than the resume probe can (both need the signer pubkey,
which only an ack carries) — so rung 2 (re-fire + re-ack) remains the primary lost-ack fix.

First-pass same-device handshakes will still sometimes lose the ack — accepted, not solved: the
cost is one extra tap and a ~2s Clave flash, never a dead session, and nothing after the
handshake depends on the fragile direction again.

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

Tooling ships at `scripts/signin-poc/` (relay probe + partner simulator; run from a laptop —
CCR container egress blocks relay WebSockets). The partner simulator proves the existing-user
concept — handshake, promptless resume probe, lock-screen signing — against the shipped App
Store build with zero iOS diffs; run it before writing any Phase-1 code.

1. Does `wss://relay.powr.build` store kind:24133 at all? (Decides how much weight re-ack vs.
   resume probe must carry.) → `scripts/signin-poc/relay-ephemeral-probe.mjs`
2. On-device: `clave://connect?uri=` cold-launch → stash → generate/import → replay → approve,
   including partner-app-killed-during-install; regression-check that `get_public_key` from the
   fresh pairing signs with no prompt (the resume probe depends on it); measure cold-launch →
   re-ack-publish latency for a re-fired pending URI vs. the partner socket's ~5–10s grace
   window (recovery ladder rung 2 depends on it).
3. SKOverlay from a scratch partner app + `canOpenURL` detection, including whether the probe
   flips to true immediately post-install without relaunching the partner app; EU-storefront
   fallback.
4. Smart App Banner OPEN-with-`app-argument` behavior on the real fallback page.

### Results — 2026-09-02 (laptop + iPhone, shipped App Store build 102)

**Test 1 — relay ephemeral probe (`relay-ephemeral-probe.mjs`). RESULT: kind:24133 is STORED,
not ephemeral, on the tested relays. Contradicts the spec's original ephemeral assumption.**

Raw (two runs; the harness prints one JSON block per relay):

```
# run A
relay.powr.build : accepted24133=true,  stored24133=true,  stored1=false (okMsg1="blocked: kind 1 is not supported on this relay"), liveForwarded24133=false
relay.damus.io   : accepted24133=true,  stored24133=true,  stored1=true,  liveForwarded24133=false
relay.nsec.app   : error "connect: read ECONNRESET"
# run B (reproduce)
relay.powr.build : accepted24133="no OK received", stored24133=true, stored1=false
relay.damus.io   : error "connect: Unexpected server response: 503"
relay.nsec.app   : error "connect: read ECONNRESET"
```

Interpretation: `stored24133=true` reproduced on `relay.powr.build` and confirmed on
`relay.damus.io`. The kind:1 control is invalid on `relay.powr.build` specifically (it *blocks*
kind:1 — see okMsg), but a positive 24133 replay needs no control: the event came back via a
`since` query, which conclusively proves both that since-queries work there and that 24133 is
retained. `relay.damus.io` supplies a valid control (`stored1=true`). `relay.nsec.app` was
unreachable both runs (inconclusive). **Action taken:** non-goal "no relay-stored-ack
assumption" struck; relay replay added as a bonus recovery rung (both edits above).

**Test 2 (client half + probe regression) — partner simulator (`partner-sim.mjs`),
cross-device (laptop sim ↔ iPhone). RESULT: PASS on all three sub-checks.**

- **Handshake ack:** received across every run (e.g. `✓ connect ack #1 … signer=0b0523ddf33d…`).
- **Resume probe promptless — PASS, strongest form.** `get_public_key` answered in 1.4–2.3s
  with **no prompt on the phone**. Proven with the phone *locked* (low-trust account, so no
  auto-sign, and no foreground UI was even possible): the `LightSigner.swift:397` always-allow
  invariant for `get_public_key` holds on the shipped build. **The STOP condition (probe
  prompts) did NOT occur — STEP 2 is unblocked.**
- **Lock-screen signing leg — PASS.** `sign_event` kind:1 returned a locally **verified**
  signature (event never published) after the request was approved from the **lock-screen
  notification banner** (long-press → Approve, Clave never foregrounded), 6.8s round-trip. A
  separate low-trust run independently exercised banner *delivery + interactive actions +
  response round-trip* via a lock-screen **Deny** (signer returned "user rejected" to the
  laptop), corroborating the push→NSE→banner path regardless of the approve/deny branch.

Operator notes that cost several takes (worth capturing for the next device session): (a) the
in-app Connect-tab scanner accepts only the raw `nostrconnect://` URI, not the
`clave.casa/connect/?uri=` Universal Link, so pass the raw URI when driving the simulator by
scan/paste; (b) when Clave is **foregrounded**, iOS routes the request to the in-app approval
popup, NOT a banner — the phone must be locked/backgrounded *before* `sign_event` arrives to
exercise the lock-screen leg; (c) the proxy on the Dell was verified healthy during the runs
(`clave-proxy` up, every push `[APNs] 200 OK`), ruling the push pipeline out as a cause.

**NEW finding — the "Universal Link opens but no ApprovalSheet" symptom was TWO separate
bugs; both are now root-caused and fixed (2026-09-02, Phase-1 branch).** An earlier revision of
this note called it "not a delivery bug" and "AASA hypothesis discarded" — that was wrong, and
it was wrong because the simulator can only fire the `clave://connect?uri=` *scheme* form
(`xcrun simctl openurl`), which never exercises a real `https` Universal Link. Corrected
account:

*Bug 1 — the Universal Link never reached the router (delivery).* On a physical iPhone
(TestFlight 1.1 (103), `idevicesyslog -p Clave`), tapping the real
`https://clave.casa/connect/?uri=` link produced **7,952 Clave log lines and zero
`[Deeplink] received` lines**: `onOpenURL` never fired. The decisive line is
`FBSceneManager … Received action(s) in scene-update: UIActivityContinuationAction` — iOS hands
a Universal Link to the app as an **NSUserActivity continuation**, not a URL-open, and
`ClaveApp` only had `.onOpenURL`. SpringBoard's entitlement serialization and the live AASA
(200, `application/json`, appID `944AF56S27.dev.nostr.Clave`, `/connect` + `/connect/` with
`?uri`) both confirm the OS-level routing to Clave was fine — the drop was inside the app.
**Fix:** `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` on the `WindowGroup` content,
funnelling `activity.webpageURL` into the same `handleDeeplink` → `.deeplinkReceived` → router
path as the schemes (log line now reads `[Deeplink] received via onOpenURL|onContinueUserActivity`).
This is why the shipped app's Universal Link has been dead since May regardless of any
downstream fix.

*Bug 2 — the sheet presentation race.* Once a URL does reach the router, UIKit silently drops
the `.sheet(item:)` presentation when the binding is set while another presentation is
animating in (cold-launch onboarding→MainTabView root swap, or the launch-time notification-
permission alert); the binding is then stuck non-nil with no sheet and later triggers no-op.
Proven on the sim with the scheme form (router → `pendingNostrconnectURI` → `deeplinkApprovalURI`
all set, no sheet). **Fix:** consume `pendingNostrconnectURI` immediately and set the sheet item
via `DispatchQueue.main.asyncAfter(+0.6s)` (`HomeView.presentPendingConnectIfNeeded`), plus
drain in `onAppear` as well as `onChange` (a value set before mount never fires `.onChange`).

*Verification.* Sim (scheme form, Bug 2 fix): `clave://connect` cold-launch → 0-account stash →
onboarding banner (domain-first "clave.casa", "Signin PoC · unverified") → Generate Key →
promote → ApprovalSheet → Approve → partner-sim received connect ack + promptless resume probe
+ verified kind:1 signature. **Physical iPhone (real `https` link, both fixes, dev build off
the branch, existing 1-account user, cold launch):** ApprovalSheet presented; partner-sim
received **connect ack (+160.2s), promptless `get_public_key` in 1.2s, and a verified kind:1
signature in 7.7s** — the first time the Universal Link entry path has ever completed a
handshake on a device. (The phone-log stream had died during the install, so the
`[Deeplink] received via onContinueUserActivity` line itself was not captured for that run; the
completed handshake is the conclusive evidence.) **Zero-account new-user path — PASSED on a physical iPhone (TestFlight 1.1 (104), real `https`
link, all accounts deleted first, cold launch):** onboarding caller banner → Generate New Key →
promoted replay → ApprovalSheet → Approve; partner-sim received **connect ack (+61.9s) from a
brand-new signer `14dbcb4f…`, promptless `get_public_key` in 1.6s, and a verified kind:1
signature in 13.5s**. That is week-1 test 2's on-device stash→generate→replay→approve gate,
closed — the full Conduit flow works on the shipped platform. Still open on-device: only the
APNs lock-screen leg on the TestFlight build carrying both fixes (test 3 of the device run).

Remaining device gates (unchanged, still open): test 2's zero-account stash→generate/import→
replay path (needs the Phase-1 iOS diff), partner-killed-during-install + re-fire re-ack timing
vs. the socket grace window, test 3 (SKOverlay + `canOpenURL` from a scratch partner app), and
test 4 (Smart-Banner OPEN `app-argument` on the real page).

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
