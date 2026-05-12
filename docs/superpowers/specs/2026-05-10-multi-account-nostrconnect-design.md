# Multi-Account NostrConnect — Connect tab + protocol opt-in

_2026-05-10 — design spec for a two-phase change. **Phase 1**: promote Connect from a HomeView sheet to a top-level cross-account `MainTabView` tab, unify single- vs multi-account-aware account binding through one `ConnectAccountPicker`. **Phase 2**: extend NostrConnect with an `accounts=multi` URI opt-in that lets one client pairing produce N parallel signer sessions in one user flow, motivated by the Tableau TweetDeck-style multi-column reader._

## Context

Clave already ships full multi-account on the data + signing layer (Phase 1 multi-account sprint, builds 33–37): `Account` model, per-signer `ClientPermissions`/`ConnectedClient` rows keyed `(signerPubkeyHex, clientPubkeyHex)`, `signer_pubkey` payload-routing in NSE, scoped-storage everywhere. What didn't ship is a connect-time UX that treats accounts as a first-class set rather than an implicit "current account" inherited from the identity bar.

Two structural problems with today's connect flow surface in light of multi-account:

1. **`ConnectSheet` is presented from `HomeView`** (HomeView.swift:165). HomeView is a per-account dashboard. This implicitly binds connect actions to whichever account the identity bar has selected, with no consent step. The `ConnectAccountContextBar` (ConnectSheet.swift:41) surfaces the implicit binding visually but doesn't ask the user to confirm. Outcome: pairing a client with a non-current account requires switching first.
2. **Account-binding consent is asymmetric across entry paths.** A `nostrconnect://` URL opened externally (deeplink path) routes through `DeeplinkAccountPicker.swift` which explicitly prompts for the binding when `accounts.count >= 2`. The in-app paste/scan path (the `ConnectSheet` entry) does not — it relies on the implicit current-account binding. Same conceptual decision, two different UX shapes.

Independently, Tableau (DocNR's TweetDeck-style multi-column Nostr reader, in active development) needs to populate its own accounts list / columns from one Clave pairing. A user with N accounts in Clave wants Tableau to come up with all N immediately, not paste-and-pair N times. This is the canonical multi-account-NIP-46 use case, and the protocol can support it with a single optional URI parameter.

This spec couples the IA fix (Connect as cross-account tab) with the protocol extension (multi-account opt-in) because they share the same surface (the unified picker) and shipping them together avoids restructuring the same code twice.

## Goals

- **Make the connect entry cross-account.** Move `ConnectSheet` out of HomeView and into a new top-level `MainTabView` tab. Connect is an action a user takes, not a property of one account.
- **Unify account-binding consent across all entry paths.** One `ConnectAccountPicker` component used by both the in-app flow and the external-deeplink flow, single-select mode by default. Auto-skip when `accounts.count == 1` so single-account users see zero added friction.
- **Make the novice path obvious.** The Connect tab opens directly to the most common case (paste/scan a code from another app — the NostrConnect side) with bunker as a clearly-labeled secondary affordance ("Or share a code from Clave"). No protocol-noun meta-decision before the user can act.
- **Enable multi-account NostrConnect via a single optional URI parameter.** A client that opts in by including `accounts=multi` in its `nostrconnect://` URI receives one `connect` ack per account the user selects in Clave's picker, all tagged with the same client pubkey. Each ack is signed by the corresponding signer's nsec, carrying enriched JSON metadata in `result` so the client can render account labels without a follow-up kind:0 fetch.
- **Backwards compat with zero coordination.** Old signers with a multi-aware URI degrade gracefully to single-account. Old clients with a multi-aware Clave never see the flag because they never set it. New Clave with old client URIs behaves exactly as today.
- **Keep the consent + privacy properties of NostrConnect intact.** Selection happens in Clave at handshake time. The URI is throwaway (Tableau's ephemeral client pubkey, nothing else). Clave never tells Tableau what accounts the user has — it only sends back the accounts the user explicitly checked.

## Non-goals

- **No multi-account bunker.** Bunker URIs encode signer pubkey + secret as a credential. A multi-signer bunker URI would leak the user's account set on URI exposure (clipboard, screenshot, log). Bunker remains single-signer per URI by design. If non-interactive multi-account provisioning is ever needed, it lives on a separate "Provisioning" surface, not in this spec.
- **No backend changes to the proxy.** Multi-account NostrConnect produces N separate `pair-client` POSTs (one per signer), each NIP-98-signed by that account's nsec. The proxy already supports per-signer pair entries from the Phase 1 multi-account sprint. No changes needed.
- **No new event kinds, RPC verbs, or relay infrastructure.** The protocol extension is one optional URI parameter plus a documented expectation that signers MAY emit multiple `connect` acks when set.
- **No NIP-46 spec PR in this scope.** A NIP draft is filed once the change is shipped and validated end-to-end with at least Tableau as a real client. Out of scope here.
- **No cross-account "all clients across all accounts" list.** Today's per-account connected-clients list (on Home) stays as-is. A cross-account view ("see every client paired with any of my accounts") is a worthwhile follow-up but not coupled to this work.
- **Per-account permission asymmetry at pair time.** Phase 2 multi-select uses one shared permissions block for all selected accounts. Per-account fine-tuning happens in `ClientDetailView` afterward (already keyed correctly: `(signer, client)`).

## Phasing

The work splits cleanly along a "no protocol changes" / "protocol changes" line. Each phase is independently mergeable, independently dogfoodable, and each phase's PR has one job.

| Phase | Scope | Protocol change | Tableau dependency |
|---|---|---|---|
| **1** | Connect tab + picker unification, single-select only | None | None |
| **2** | `accounts=multi` URI flag, multi-select picker mode, N-up handshake loop | One optional URI param, documented expectation that signer MAY emit multiple acks | Tableau must accumulate acks within a listening window |

Phase 1 lands the IA fix and is a UX win for everyone — single-account users get explicit-consent on deeplink (already true today), multi-account users get explicit-consent in-app (new). Phase 2 layers multi-account capability on the foundation Phase 1 lays.

## Phase 1 — Connect entry restructure + picker unification

### Information architecture

Today:

```
MainTabView
├── Home (per-account)
│   └── ConnectSheet (sheet, presented from HomeView)
│       ├── ConnectAccountContextBar (current account, implicit binding)
│       ├── Bunker tab
│       └── Nostrconnect tab
├── Activity (cross-account)
└── Settings (cross-account)

External deeplink → DeeplinkAccountPicker (explicit binding, when accounts ≥ 2) → ApprovalSheet
```

After Phase 1:

```
MainTabView
├── Home (per-account)            ← Connect button + ConnectSheet removed
├── Connect (cross-account)        ← NEW
│   ├── NostrConnect surface (default, primary)
│   │   ├── Camera viewfinder + paste field
│   │   └── On parse: ConnectAccountPicker (single-select) → ApprovalSheet
│   └── "Or share a code from Clave" → bunker view
│       └── ConnectAccountPicker (single-select) → bunker URI render
├── Activity (cross-account)
└── Settings (cross-account)

External deeplink → ConnectAccountPicker (single-select) → ApprovalSheet
```

The 4-tab bar is the simplest valid placement. (A center-prominent action button is also viable; a tab is cheaper.)

### `ConnectAccountPicker` — the unified consent component

Lives at `Clave/Views/Home/Connect/ConnectAccountPicker.swift` (renamed from `DeeplinkAccountPicker.swift`).

```swift
struct ConnectAccountPicker: View {
    enum Mode {
        case single   // bunker, single-NostrConnect, deeplink
        case multi    // Phase 2 only: NostrConnect with accounts=multi
    }
    let mode: Mode
    let parsedURI: NostrConnectParser.ParsedURI?  // nil for bunker (no URI yet)
    let onPick: (_ pubkeys: [String]) -> Void
    // ...
}
```

Phase 1 uses `.single` exclusively — `onPick` always receives a one-element array. The `Mode` enum is introduced now so Phase 2's call sites don't reshape the type signature; the `.multi` case lands in Phase 2.

Auto-skip rule (preserves today's `DeeplinkAccountPicker` behavior, extended to all callers): if `appState.accounts.count == 1`, skip rendering the picker entirely and call `onPick([appState.accounts[0].pubkeyHex])` directly. Single-account users never see this UI.

Pre-selection in `.single` mode: the most-recently-active account (i.e. `appState.currentAccount`) is highlighted as the default. One tap on Approve completes the flow.

### Connect tab — UX shape γ (asymmetric primary)

The tab opens directly to the NostrConnect input surface — camera viewfinder + paste field + help link — with bunker available via a secondary affordance below.

```
┌─────────────────────────────────────────────────┐
│            Connect Client            [Done]     │  ← inline title
├─────────────────────────────────────────────────┤
│                                                 │
│           ┌───────────────────────┐             │
│           │                       │             │
│           │   [QR scanner view]   │             │  ← AVFoundation viewfinder
│           │                       │             │     (ConnectNostrconnectTabView's
│           │                       │             │      cameraSection, reused)
│           └───────────────────────┘             │
│                                                 │
│   ── PASTE A URI ──                             │
│   [ Paste Nostrconnect URI ]                    │  ← clipboard button
│   nostrconnect://...                            │  ← text field
│                                                 │
│   ⓘ What's a nostrconnect URI?                  │  ← ConnectHelpSheet trigger
│                                                 │
│   ─────────────────────────────────             │
│                                                 │
│   Or share a code from Clave →                  │  ← secondary affordance,
│   Use Clave as your signer in another app          push to bunker view
│                                                 │
└─────────────────────────────────────────────────┘
```

Tapping the secondary affordance pushes a child route showing the bunker URI/QR for the chosen account. The user picks the account first (via `ConnectAccountPicker`, auto-skipped if N=1), then the URI renders.

Why γ over a symmetric segmented control:

- **Supersedes the symmetric segmented control shipped in the 2026-05-04 ConnectSheet redesign** — same single-sheet primitive, but the multi-account flow benefits from asymmetric primary/secondary surfacing rather than equal-weight method tabs. The 2026-05-04 design optimized for "make the binary obvious"; this design optimizes for "make the novice path obvious," with the binary still legible via the secondary affordance.
- A novice's first encounter with Clave is overwhelmingly "I tapped Sign in with Clave in some app and got a code — now what?" The primary surface answers exactly that.
- Bunker requires the user to already understand they need to give a code to another app. Anyone who understands that can find a clearly-labeled secondary affordance.
- Asymmetric framing matches asymmetric usage frequency.

If field testing shows bunker discoverability suffers, promotion from secondary affordance to peer tab (back to a segmented control) is a one-line change.

### Bunker flow inside the Connect tab

1. User taps "Or share a code from Clave →"
2. `ConnectAccountPicker(mode: .single, parsedURI: nil)` presents (auto-skips if N=1)
3. User picks the account they want to share a bunker URI for
4. View pushes/renders the bunker URI + QR for that account, using the existing `ConnectShowQR`-style content (currently in `ConnectBunkerTabView`)

The picker fires *first* in this flow because there's no URI to parse — the user's choice of account determines which signer's nsec backs the URI. This is the asymmetry vs. NostrConnect noted earlier.

### NostrConnect flow inside the Connect tab

1. User pastes URI or scans QR
2. `NostrConnectParser.parse` validates
3. `ConnectAccountPicker(mode: .single, parsedURI: parsed)` presents (auto-skips if N=1)
4. User picks the account
5. `ApprovalSheet` presents with `boundAccountPubkey` set
6. On approve, `handleNostrConnect` runs as today (under `UIBackgroundTask`)

The picker fires *between* parse and approval — same position as today's deeplink path. The URI's metadata (name, image) is shown in the picker header so the user knows which client they're authorizing.

### `handleNostrConnect` signature adoption

Phase 1 also lands the call-shape change that Phase 2 will need. Adopting the array shape now keeps Phase 2's PR focused on "wire up `N > 1` semantics + multi-select picker mode" rather than reshaping the API across all call sites.

```swift
// Before (today):
func handleNostrConnect(parsedURI: NostrConnectParser.ParsedURI,
                        permissions: ClientPermissions) async throws

// After Phase 1 (always 1-element array; Phase 2 enables N > 1):
func handleNostrConnect(parsedURI: NostrConnectParser.ParsedURI,
                        signerPubkeys: [String],
                        permissions: ClientPermissions) async throws -> HandshakeResult

struct HandshakeResult {
    let succeeded: [String]
    let failed: [(signerPubkey: String, error: Error)]
}
```

Phase 1 callers (the in-app Connect tab path and the deeplink path) always pass a one-element `signerPubkeys` array — the single chosen pubkey from the picker. `HandshakeResult.succeeded` always has exactly 1 element; `failed` has 0 or 1. Behaviorally identical to today's signature. The shape change is mechanical, no new logic.

### What gets removed or repurposed

- **`HomeView`'s "Connect a Client" button** (HomeView.swift:165 sheet trigger): removed. The empty-state CTA on Home for a user who has no connected clients can either point to the Connect tab ("Tap Connect to pair your first app") or be removed entirely; UX call.
- **`ConnectAccountContextBar`** (ConnectSheet.swift:41): removed from the `ConnectSheet` surface. The picker step replaces its function. If the bar is reused elsewhere (verified via grep before removal), those usages stay.
- **`DeeplinkAccountPicker`**: renamed to `ConnectAccountPicker`. Today's deeplink-route call site is updated to use the new name; behavior is unchanged for Phase 1.
- **`ConnectSheet` itself**: contents move into the new tab view. The sheet shell goes away.

### Migration path for existing testers

No data migration. UI-only restructure. Tap targets move; everything else (paired clients, accounts, activity) stays put. Worth a one-line release-note: "Connect a Client is now its own tab" — testers will look for the Home-screen button.

## Phase 2 — Multi-account NostrConnect protocol opt-in

### Protocol shape (Shape 1, locked)

The `nostrconnect://` URI gains one optional parameter, `accounts=multi`:

```
nostrconnect://{client_pk}?relay=wss://...&secret={secret}&accounts=multi&perms=...&name=...
```

When Clave parses a URI with this flag set, it presents `ConnectAccountPicker(mode: .multi, parsedURI: parsed)`. The user selects N ≥ 1 accounts. For each selected account, Clave runs the existing handshake once with that account's nsec — sequentially, all under one `UIBackgroundTask` window. Each iteration emits one kind:24133 `connect` ack tagged `#p:client_pk`, encrypted from that signer's nsec, and POSTs `pair-client` to the proxy NIP-98-signed by that nsec.

The client receives N kind:24133 events tagged with its own pubkey. Each event's `pubkey` field identifies a distinct signer. The client builds its accounts list from the set of `pubkey`s observed within a listening window (see Tableau client-side requirements below).

Why Shape 1 over alternatives:

- The protocol already permits multiple acks per `#p` tag — the spec just doesn't formalize the case. We're adding an opt-in signal so ambiguity is replaced by intent.
- Subsequent `sign_event` RPCs are encrypted to a specific signer pubkey. Each session is `(client_pk, signer_pk)`-keyed regardless. A "single ack with a list of pubkeys" alternative (Shape 3) saves nothing on the wire — the client still needs N session keys — and adds a "primary signer" awkwardness because the kind:24133 event itself has one `pubkey` field.
- `perms`-overloading (Shape 2) is rejected — `perms` expresses request-time permissions, not session shape, and signers parse unknown perms tokens unpredictably in practice.

### `result` field shape — enriched per-ack metadata

Today's NIP-46 `connect` ack carries `result: "ack"` or `result: "<echoed_secret>"`. Clave already returns the secret-echo form (see `LightSigner.swift:564-568`). Multi-account acks carry a small JSON object instead:

```json
{
  "echoed_secret": "abc123...",
  "name": "alice",
  "picture": "https://..."
}
```

`echoed_secret` preserves the existing handshake validation (clients today check secret-match per the `nip46-interop-gotchas` post-stackernews fix). `name` and `picture` come from the account's cached `kind:0` profile (`Account.profile.displayName`, `Account.profile.picture`). The client can populate column headers / account-switcher rows immediately without a follow-up profile fetch.

This is purely additive: a client that doesn't parse the JSON shape but does string-compare the secret still validates the handshake correctly, because if `result` looks like JSON it won't match the secret string and the existing fallback path applies. Clients that *do* string-compare the secret as a sole validation will fail to validate multi-account acks — but this is a multi-account-aware client by definition (it set `accounts=multi`), so it's responsible for parsing the new shape.

For backwards safety, the single-account flow (no `accounts=multi` flag) **continues** to emit `result: "<echoed_secret>"` exactly as today. Only the multi-account path uses the JSON shape.

### URI parser change

`NostrConnectParser.ParsedURI` gains:

```swift
let isMultiAccount: Bool  // true iff accounts=multi was present
```

The parser sets this from the URI's query parameters. All existing call sites continue to work; they just see `false` for the field.

### NostrConnect flow in multi mode

Parallel to Phase 1's single-mode NostrConnect flow, with multi-select at the picker step and the same two-step picker → approval shape:

1. User pastes URI or scans QR
2. `NostrConnectParser.parse` validates; `isMultiAccount: true` is set on `ParsedURI`
3. `ConnectAccountPicker(mode: .multi, parsedURI: parsed)` presents with checkbox rows (auto-skipped if `appState.accounts.count == 1` — collapses to a one-element flow)
4. User selects ≥ 1 accounts (defaults + cap rules per the picker section below), taps Continue
5. `ApprovalSheet` presents in multi mode, showing the selected accounts + shared permissions block + "Approve N accounts" button
6. On approve, `handleNostrConnect(parsedURI:, signerPubkeys: [pk_1, ..., pk_N], permissions:)` runs the sequential loop inside one `UIBackgroundTask`
7. Progress UI on the same `ApprovalSheet` during the loop (see "Progress UI during the loop" below)
8. Partial-failure summary or auto-dismiss on success (see "Partial-failure UX" below)

**Two sheets, not one.** Picker stays focused on "which accounts"; `ApprovalSheet` stays focused on "what permissions + commit." Same shape as Phase 1's NostrConnect flow and today's deeplink-route flow — single mode and multi mode differ only in picker selection semantics, not in flow structure.

### `ConnectAccountPicker` — multi-select mode

In `.multi` mode:

- Each row gains a checkbox (or trailing checkmark) instead of being a tap-to-pick button
- **Continue button** reads "Continue with N accounts" with N = selected count — picker selects accounts; the next sheet (`ApprovalSheet`) confirms permissions and runs the actual approval. Two-step picker → approval flow stays consistent with Phase 1 and the deeplink path.
- Default selection: all accounts checked when `appState.accounts.count <= 5`; none checked when > 5 (avoids accidental bulk-pair on power users with many accounts)
- Rows that have hit the cap on the proxy (5 distinct paired clients per signer, enforced by `pair-client`) are rendered disabled with a "5/5 clients" badge inline, pre-flighted before the picker presents (see "Cap pre-flight" below)
- The header line updates: "Tableau wants to connect to multiple accounts." (vs the single-mode "Choose the identity to use for **Tableau**.")

### `ApprovalSheet` — multi-mode shared permissions

When called with N ≥ 2 selected accounts, `ApprovalSheet` shows:

- Header: "Tableau is requesting to sign for N accounts"
- A small inline list of the N selected accounts (avatar + petname/displayName + truncated pubkey), tappable to expand
- A single shared permissions block — the same `perms` from the URI applies to each account
- "Approve" button reads "Approve N accounts"

Per-account permission asymmetry is fine-tunable in `ClientDetailView` post-pair (already keyed `(signer, client)`).

### `handleNostrConnect` — N-up handshake loop

The function signature was already adopted in Phase 1 (see "`handleNostrConnect` signature adoption" above) — it accepts `signerPubkeys: [String]` and returns `HandshakeResult`. Phase 2 wires up the `N > 1` path on the same signature; no API reshape, no new call-site changes outside this function.

Loop structure:

```swift
for signerPubkey in signerPubkeys {
    do {
        try await runSingleConnect(parsedURI: parsedURI,
                                   signerPubkey: signerPubkey,
                                   permissions: permissions)
        succeeded.append(signerPubkey)
    } catch {
        failed.append((signerPubkey, error))
    }
}
```

Sequential, not concurrent: each handshake is ~1–2s; `UIBackgroundTask` covers ~30s; sequential makes partial-failure semantics legible; all acks go to the same relay set so concurrency wins nothing. Each iteration internally wraps the existing flow (encrypt → publish → POST `pair-client` → write `ClientPermissions` + `ConnectedClient` rows + ActivityEntry) which already accepts a `signer:` parameter from the Phase 1 multi-account sprint.

In multi mode this means **N `ClientPermissions` rows are written, one per `(signer_pubkey_i, client_pubkey)` composite key** — all N carry the same `perms` value copied verbatim from the URI. Per-account permission customization is post-pair via `ClientDetailView` (already correctly keyed by composite). Same shape for `ConnectedClient` rows and `ActivityEntry` writes — N records, one per signer.

`UIBackgroundTask` is started at the *outer* call site (the Connect-tab submit handler — same role as today's `ConnectSheet.submitApproval`, just relocated to the Phase 1 tab view) and wraps the full N-iteration loop. If the budget is approached (~25s in, system warning fires), the `expirationHandler` records remaining iterations to `pendingPairOps` so a future foreground/wake can finish. Mitigation, not common-case behavior.

### Progress UI during the loop

While `handleNostrConnect` runs the sequential loop, the ApprovalSheet enters a progress state:

- "Pairing N of M…" text reflecting the current iteration (live count, advances per-iteration)
- The currently-being-paired account row in the selection list is visually highlighted (e.g. spinner + accent background)
- Already-succeeded rows show a checkmark; not-yet-attempted rows stay in their pre-Approve appearance
- The Approve button is replaced by a non-tappable progress indicator
- Sheet dismissal is disabled while the background task is in-flight (no swipe-down, no Cancel)

This gives the user a per-iteration sense of progress that matches the sequential loop's actual semantics, instead of one opaque "Connecting…" spinner over the whole batch.

### Partial-failure UX

After the loop, the result screen shows:

- **Success-only** (typical): brief checkmark + "Tableau is now signed in for Alice, Bob, Carol" → auto-dismiss after ~1.5s
- **Mixed**: "3 of 4 paired successfully. Dave failed: <reason>. [Retry Dave] [Done]" — **sheet does NOT auto-dismiss**; stays open until user taps Done or Retry. A partial-success result is a state the user needs to actively acknowledge.
- **All-failure**: existing error path (today's `connectionError` alert)

Retry is per-failed-account; tapping Retry runs `runSingleConnect` for just that signer.

### Cap pre-flight in the picker

The proxy enforces 5 pairs/signer (`pair-client` returns 401 when exceeded). Pre-flighting in the picker:

- When the picker presents in `.multi` mode, `appState` resolves each account's current pair count from `SharedStorage.getConnectedClients(for:)`.
- Accounts at 5/5 render disabled with a "5/5 clients" badge.
- Tapping a disabled row shows an inline hint: "This account has 5 paired clients. Revoke one in [account]'s settings to add another."

Pre-flighting at picker render-time (rather than after Approve) is deliberate: the cap constraint stays visible while the user is still selecting accounts, giving them the option to deselect or revoke before committing. Surfacing a cap miss mid-loop leaves a partial-pair state with no clear in-flow recovery, which is the UX we want to avoid.

The check is best-effort, not authoritative: in the (small) window between picker render and `pair-client` POST, another flow could hit the cap. If `pair-client` 401s mid-loop, that account ends up in `failed` with an "account-cap" error and the partial-failure UX surfaces it.

### Backwards-compat matrix

| Signer | Client URI | Result |
|---|---|---|
| Old Clave (pre-Phase-2) | `accounts=multi` URI | Unknown URI param ignored. Single-account picker (or current implicit binding). One ack arrives. Multi-aware client gets 1 account, not 0. **Graceful degrade.** |
| New Clave (Phase 2) | URI without `accounts=multi` | Default single-account flow, single-select picker. Identical to today. |
| New Clave | `accounts=multi` URI | Multi-account flow per this spec. |
| Other signers (Amber, nsec.app, etc.) | `accounts=multi` URI | Each implementation handles unknown params per its own tolerance. None are known to fail-hard on unknown URI params today. |

No breakage in any cell.

### Tableau client-side requirements

Tableau (the multi-column reader) is the motivating client. To opt in:

1. **Generate one ephemeral keypair, build one URI** with `accounts=multi`:
   ```
   nostrconnect://{client_pk}?relay=wss://relay.nsec.app&secret=...&accounts=multi&perms=sign_event:1,sign_event:6,sign_event:7,nip04_decrypt,nip44_decrypt&name=Tableau
   ```
2. **Subscribe to kind:24133 events with `#p:client_pk`** as today.
3. **Accumulate acks within a listening window**, instead of completing on first ack. The "first ack → pair complete" pattern is the default in many NIP-46 client libraries (NDK's `blockUntilReadyNostrConnect`, single-account `nostr-tools` flows) and is the specific anti-pattern Tableau must avoid:
   - Time-bounded window (recommended: 60s, with explicit "Done" button to short-circuit) — generous tail to absorb p99 handshake latency on flaky relays / larger N
   - Keep the kind:24133 subscription open for the full window — do **not** unsubscribe on first received ack
   - Each received ack: validate `echoed_secret` matches the URI secret, parse `name`/`picture` from JSON `result`, store the (signer_pk, name, picture) tuple as one of the user's accounts
   - On window expiry or user-tapped Done, close the subscription and surface the resulting accounts list
4. **Show progress during the window**: "1 connected, listening for more (53s)…" with the Done button. This is the user-visible counterpart to Clave's "Pairing 2 of 4…" progress.
5. **Per-signer session state**: subsequent `sign_event` RPCs are NIP-44/04-encrypted to the specific signer pubkey, exactly as in single-account NIP-46. Tableau already needs per-signer session keys regardless of multi-account.

Tableau's NIP-46 stack is `nostr-tools` (verified via `nostr-tools_nip46` in its Vite deps cache), not NDK, so the recent NDK bunker-handshake bug is not a blocker. But the "first ack → complete" anti-pattern is the default in single-account `nostr-tools` flows too — Tableau-side has **real code work** to override that default, not just a library audit.

**Tableau-side plan location.** The Tableau implementation work for opt-in URI emission, listening-window UI, Done button, and the unsubscribe-on-first-ack override lives in the Tableau repo at `/Users/danielwyler/tableau/docs/superpowers/plans/` as its own slice (likely Slice D or later in their numbering — current slices are A1, B, C, and the in-flight Slice CV "account-isolation" design). That brainstorm is deferred until this Clave-side spec's Phase 2 is close to merge, so the Tableau plan tracks the actual landed shape rather than a forecast. Integration target: Tableau's existing `client.signers` Map (referenced in `tableau/docs/superpowers/specs/2026-05-10-tableau-account-isolation-design.md`) — the new slice adds the connect-time flow that populates the Map with N entries from one Clave pairing.

## Documentation + ecosystem

- **`docs/nip46-compatibility.md`** (Clave repo): add a "Multi-account NostrConnect" column to the client matrix. Initial values: Tableau ✅, all others ❌ (no opt-in).
- **`docs/integrations.md`** (Clave repo): document the `accounts=multi` URI parameter for client developers, including the listening-window expectation and `result` JSON shape.
- **clave.casa**: update `/connect/?uri=` inbound fallback to surface multi-account capability when the URI carries the flag.
- **Future NIP draft**: file once Phase 2 ships and Tableau validates end-to-end. The minimalism of the change (one optional URI param + a documented expectation that signers MAY emit multiple acks) makes this a small, focused proposal.

## Risks / open questions

1. **Relay tolerance for N rapid kind:24133 events on one `#p` tag.** Some relays rate-limit per-source-pubkey (fine — N different signer pubkeys), some per-destination (`#p` tag) might balk. Worth a probe against `wss://relay.nsec.app`, `wss://relay.damus.io`, and `wss://relay.powr.build` before merging Phase 2. If a target relay rate-limits, mitigation is per-iteration delay (e.g. 200ms) inside the handshake loop — adds at most ~1s for 5 accounts, well within the budget.
2. **`UIBackgroundTask` budget at upper bounds.** ~30s system grant. 5 accounts × 2s = 10s comfortable. 10 accounts × 3s = 30s edge. If expiration warning fires mid-loop, queue remaining iterations into `pendingPairOps` and complete on next foreground/wake. Worth a smoke test at N=10 if any tester has that many accounts.
3. **Picker default in `.multi` mode.** All-checked (when ≤ 5) is fast for the common Tableau case but could surprise a user who expected to opt in account-by-account. Initial UX testing should confirm; fallback is none-checked-by-default.
4. **`result` JSON shape for clients that string-compare secrets.** The `echoed_secret` field is named explicitly so a JSON-aware client extracts it, but a client that does `result == secret` as its sole validation will fail on multi-account acks. Mitigated by the fact that any client setting `accounts=multi` is multi-aware by definition. Document this clearly in `integrations.md`.
5. **NIP-46 spec wording.** The current spec says "the user-signer receives the request, displays a prompt for the user, who can authorize or reject the connection" — singular. We're not violating this (it's N independent connect responses produced by one user prompt) but the future NIP draft text needs to be careful about framing this as sugar over N single connects rather than a new "multi-connect" RPC.
6. **Connect tab vs center-action button.** A 4-tab bar is the simplest placement; some apps elevate "create" actions to a center-prominent button instead of a tab item. Pure UX call; doesn't change the IA. Decision deferred to Phase 1 implementation; default is a 4th tab.
7. **HomeView empty state after Connect button removal.** A user with zero paired clients on Home today sees a "Connect a Client" CTA; that goes away. Either replace with text pointing at the Connect tab ("Tap Connect to pair your first app") or remove the empty-state block entirely. UX call during Phase 1.

## Out of scope / future work

- **Cross-account "all clients" view.** A view showing every paired client across all accounts (e.g. inside Settings or as a tab section) is logically adjacent to the cross-account framing of this spec but not required. Phase 3 candidate.
- **Per-account permission asymmetry at pair time.** Phase 2 uses one shared permissions block. Per-account customization at pair-time (different `perms` for different accounts in one multi-pair) is a UX complexity not justified by current need. Post-pair customization in `ClientDetailView` is sufficient.
- **Provisioning surface for non-interactive flows.** Server-side automation, CI bots, batch credential issuance — these are valid use cases for a pre-encoded multi-signer URI (the rejected Y2 shape). They live on a different surface, not in NostrConnect.
- **NIP draft.** Filed after Phase 2 ships and Tableau validates; not blocking.
- **NDK multi-account NostrConnect support.** If/when NDK adds it, Clave's documented protocol is what they'd target. Tableau's non-NDK stack means this isn't a blocker for Phase 2.

## Plan + verification

Implementation plan to be drafted via `superpowers:writing-plans` after this spec is approved. Verification is per-phase:

**Phase 1 acceptance:**
- Connect tab present in `MainTabView`, opens to NostrConnect-primary surface.
- Bunker secondary affordance pushes to bunker view, picker fires before URI render (auto-skipped for N=1).
- NostrConnect paste/scan routes through `ConnectAccountPicker` (single-select), then `ApprovalSheet`, exactly as deeplink does today.
- HomeView no longer presents `ConnectSheet`; the old button is gone.
- All existing tests pass; no regressions in existing NostrConnect / bunker flows.
- Smoke test on real device: pair a client to each of 2+ accounts via the new tab; pair via the deeplink path; bunker URI render for non-current account works without first switching identity bar.

**Phase 2 acceptance:**
- Phase 1 acceptance plus:
- URI parser sets `isMultiAccount = true` for `accounts=multi` URIs and `false` otherwise (unit test).
- Picker `.multi` mode renders correctly with cap-disabled rows (unit test + smoke).
- `handleNostrConnect` N-up loop returns correct `HandshakeResult` for all-success, partial, all-fail scenarios (unit test).
- Backwards-compat matrix verified: old single-account URI through new Clave behaves as today (smoke test).
- End-to-end with Tableau: paste multi URI in Clave, select 2+ accounts, approve, observe Tableau receive N acks within listening window and surface N accounts (integration smoke).
- Manual probe of relay tolerance for rapid N kind:24133 events on `#p:client_pk` against the target relay set.
- **Scope boundary:** Tableau-side acceptance (URI emission, listening-window UI, Done button, override of `nostr-tools` unsubscribe-on-first-ack default) is verified against a separately-drafted plan in `/Users/danielwyler/tableau/docs/superpowers/plans/`. The end-to-end smoke test in this branch validates Clave's side of the wire (N acks emitted, N `pair-client` POSTs succeed). Tableau's side of the wire is validated in Tableau's own plan cycle.
