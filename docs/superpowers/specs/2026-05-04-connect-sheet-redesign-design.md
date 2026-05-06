# ConnectSheet redesign — single sheet with segmented control

_2026-05-04 — design spec for v0.2.1 (or v0.3.0 depending on bundling). Scope: replace the 3-card method chooser in `ConnectSheet` with a single sheet whose body switches between a Bunker tab and a Nostrconnect tab via a segmented control. Plus a small bug fix on `HomeView`'s empty-state CTA bundled with this work._

## Context

The current `ConnectSheet` greets the user with three large method cards stacked vertically:

1. **Show my QR (bunker)** — pushes `ConnectShowQRView` onto a `NavigationStack`
2. **Scan client's QR (Nostrconnect)** — pushes `ConnectScanQRView`
3. **Paste Nostrconnect** — pushes `ConnectPasteView`

Three problems with this:

- **The split is conceptually wrong.** There are only two NIP-46 pairing modes — Bunker (Clave hands a credential to a client) and Nostrconnect (a client hands a credential to Clave). Cards 2 and 3 are both Nostrconnect, just with different input methods (camera vs. typed). Splitting them as siblings to "Show my QR" implies they're three equivalent options.
- **Extra navigation step.** Every pairing requires choosing a card first, then operating inside the pushed focused view. That's two interactions before the user can scan or copy.
- **Discoverability is poor inside the focused views.** Brian Green (@bfgreen) reported in Clave/POWR Testers chat (2026-05-04) that he opened `ConnectShowQRView` (the Bunker tab), saw the QR code, and concluded the bunker URI text was no longer available. The string IS there — rendered below the QR in caption-2 monospace — but it has no header, blends with surrounding helper text, and can fall below the scroll fold on smaller devices. Quote: "oh wait... I can't create a bunker string anymore??? just QR." That's a discoverability bug, but it lives downstream of the same root cause: pushing into a focused view fragments what should be a single discoverable page.

This redesign collapses the 3-card chooser into a single sheet with a segmented control between Bunker and Nostrconnect. The Nostrconnect tab combines camera + paste field on one screen — no sub-navigation. It also bundles a small unrelated fix on `HomeView`'s empty-state "Connect a Client" CTA where the `plus.circle.fill` icon's negative-space plus rendered the same color as the button background, making the icon invisible.

## Goals

- **Make the binary obvious.** Users see two tabs (Bunker / Nostrconnect), not three method cards. The segmented control communicates that these are mutually exclusive modes of the same underlying flow.
- **Reduce navigation depth.** No more "tap a card, get pushed into a focused view" — the relevant content is rendered directly under the segmented control on tab change.
- **Fix the bunker URI discoverability bug.** The URI text gets a clear "Bunker URI" header, larger font, tap-to-copy affordance.
- **Self-contained Nostrconnect input.** Camera viewfinder + paste field + help affordance all on one screen. No "switch to paste" sub-navigation.
- **Keep ecosystem terminology.** Tab labels stay as "Bunker" and "Nostrconnect" — these are the spec terms users will see in the rest of the Nostr ecosystem. Non-technical users get a help link on the Nostrconnect tab and the existing AccountTheme styling for visual scaffolding.
- **Drive-by fix on the empty-state CTA in `HomeView`** — two parts:
  1. Swap `plus.circle.fill` → `plus` so the icon glyph is visible against the `borderedProminent` button fill.
  2. Apply `.tint(theme.accent)` so the CTA's prominent fill matches the active account's gradient identity (consistent with the smaller `Pair New Connection` button below it which already uses `theme.accent`).

## Non-goals

- **No change to the underlying pairing flow.** `NostrConnectParser`, `AppState.handleNostrConnect`, `ApprovalSheet`, and the rest of the post-parse pipeline are untouched. This is a UI/IA refactor, not a protocol change.
- **No deeplink integration changes.** `DeeplinkRouter` continues to bypass `ConnectSheet` entirely for direct `nostrconnect://` URIs, Universal Links from clave.casa, and `clave://` scheme deeplinks. Pre-parsed URIs route directly to `ApprovalSheet` (or `DeeplinkAccountPicker` in the multi-account fork) as today.
- **Bug 5 (NIP-65 outbox), Bug 7 (pending count semantic), Bug 8 (rotate-bunker-secret UX cleanup)** from the v0.2.1 backlog are not addressed here. They live in `~/hq/clave/BACKLOG.md`.

## Design — the new ConnectSheet

```
┌─────────────────────────────────────────────────┐
│  Cancel        Connect Client            [Done] │  ← inline navigation title
├─────────────────────────────────────────────────┤
│                                                 │
│           [ Bunker ]  [ Nostrconnect ]          │  ← segmented control (default: Bunker)
│                                                 │
│   ─── ConnectAccountContextBar (unchanged) ───  │  ← only renders if multiple accounts
│                                                 │
│            { tab body — see below }             │
│                                                 │
└─────────────────────────────────────────────────┘
```

The shell is one `NavigationStack` with `.navigationTitle("Connect Client")` + `.navigationBarTitleDisplayMode(.inline)`. No more `navigationDestination(for: ConnectMethod.self)` — the segmented control swaps the body inline. The `ConnectAccountContextBar` (existing) is rendered above the tab body so the user always sees which account they're pairing under.

### Bunker tab (default)

```
            ┌─────────────────────┐
            │                     │
            │                     │
            │     [ QR code ]     │   ← 240×240 max, white card,
            │                     │     same generator as today
            │                     │
            └─────────────────────┘
              Tap QR or "Copy" to copy URI

   ┌───── Bunker URI ─────────────────────────┐
   │  bunker://abc123…@relay.powr.build?…      │   ← header label,
   │                                            │     monospace caption,
   │                                            │     tap-to-copy
   └────────────────────────────────────────────┘

   [ Copy URI ]                  [ New secret ]   ← prominent + bordered
```

Components, top to bottom:

- **QR card.** 240×240 max, white background, rounded 12pt corners. Generated from `appState.bunkerURI` via the same CIFilter pipeline currently in `ConnectShowQRView.qrImage(for:)`. Tap presents the existing full-screen `QRCodeView` sheet for clearer scanning at a distance. Long-press shows the standard iOS share menu (system behavior — no custom code).
- **Tap-to-copy hint.** A small caption between QR and URI: "Tap QR or **Copy** to share this bunker URI." Sentence-case, secondary color. Replaces the existing "Tap for full screen" caption — the new help is more useful since a fresh user doesn't know the QR is also a tap-to-copy target.
- **Bunker URI section.** A labeled card. Header label "Bunker URI" in caption-1 secondary color, the URI text below in monospace caption-2 wrapped in a `tertiarySystemGroupedBackground` rounded rect. Same `lineLimit(3)` truncation as today (URIs are usually 200-400 chars; 3 lines is enough to establish "this is a string" without dominating the screen). The whole section is tap-to-copy — `Button { } label: { sectionContent }` with `.buttonStyle(.plain)`.
- **Action row.** Two buttons in an HStack:
  - **Copy URI** — `borderedProminent`, AccountTheme-tinted, with the "Copied" checkmark + haptic + 2-second auto-revert pattern already in `ConnectShowQRView.swift:73-79`. Carry that logic forward.
  - **New secret** — `bordered`, secondary-colored. Calls `appState.rotateBunkerSecret()` plus an `UIImpactFeedbackGenerator(style: .medium)` impact. Same as today.

The existing helper text "Single-use — the secret rotates once a client connects" is removed. Auto-rotation already covers this case; the helper text was educating about a behavior the user doesn't need to actively manage.

### Nostrconnect tab

```
   ┌─────────────────────────────────────────┐
   │                                         │
   │                                         │
   │           [ camera viewfinder ]         │   ← 1:1 aspect, 12pt rounded,
   │            (live AVFoundation)          │     existing scanner
   │                                         │
   │                                         │
   └─────────────────────────────────────────┘

   Or paste a URI
   ┌─────────────────────────────────────────┐
   │  nostrconnect://…                       │   ← .text input, mono caption-2
   └─────────────────────────────────────────┘

           ⓘ What's a nostrconnect URI?           ← tap target,
                                                    opens explanatory sheet
```

Components, top to bottom:

- **Camera viewfinder.** Existing `ConnectScanQRView`'s scan logic, extracted into a child component so the tab can compose it with the paste field. The `onSwitchToPaste` callback is removed (paste is always visible — no switching). On a successful scan, calls `onParsed(parsedURI)` exactly as today; the parent wires that to `parsedURI = uri` which presents `ApprovalSheet`.
- **"Or paste a URI" input.** Header label "Or paste a URI" in caption-1 secondary, then a single-line `TextField` with monospace caption-2 styling, placeholder `nostrconnect://...`, `.textContentType(.URL)`, no autocorrect / capitalization. On submit (Enter / Done) or paste-then-blur, the text is fed through `NostrConnectParser`. If valid, `onParsed(parsedURI)` fires — same flow as scan. If invalid, the field gets a red error border + caption "That doesn't look like a valid nostrconnect URI."
- **Help link.** A row aligned to the bottom of the tab body: "ⓘ What's a nostrconnect URI?" — semibold caption-1, AccountTheme-accent color, tappable. Tapping presents a small sheet (`presentationDetents([.medium])`) with the explanatory copy below.

#### Help-sheet copy (draft)

> **What's a nostrconnect URI?**
>
> Some Nostr web apps and clients let you sign in with a remote signer like Clave. When you choose "Connect a remote signer," they show you a code that starts with `nostrconnect://`.
>
> **Bring that code here:** scan the QR with the camera above, or copy the URI and paste it.
>
> The URI tells Clave which client wants to connect, where to reach it, and which encryption keys to use. After you paste it, Clave will ask you to approve the connection — including which kinds of events the client can sign.

Sentence-case, three short paragraphs, no jargon beyond `nostrconnect://` itself (which is the literal string they need to recognize). Includes a "what happens next" so users know they're not committing to anything by pasting.

### Edge cases

#### Camera permission denied

When iOS reports `AVCaptureDevice.authorizationStatus(for: .video) == .denied` (or `.restricted`):

- The viewfinder area renders a placeholder card instead of the live preview: dark background, camera-with-slash SF Symbol, secondary-color text "Camera access denied" + a tappable "Open Settings" link that calls `UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)`.
- The paste field below stays unchanged. A user with no camera access can still paste a URI — the tab is still useful.
- The help link stays at the bottom.

This matches the existing `ConnectScanQRView` permission-denial handling pattern. If the existing handling is less graceful, harmonize it as part of this work.

#### Camera permission first-grant flow

First time the user lands on the Nostrconnect tab, iOS will show the standard system permission sheet. While that's resolving, the viewfinder area shows a neutral placeholder ("Requesting camera access…") so the tab doesn't briefly flash an empty state. Once granted → live preview. Once denied → see the denial path above.

#### Deeplink-handled URIs

Universal Links from clave.casa, raw `nostrconnect://` URLs from system Share, and `clave://` scheme deeplinks all continue to bypass `ConnectSheet` entirely. They route through `DeeplinkRouter` → `AppState.handleNostrConnect` → `ApprovalSheet` directly. No change to the deeplink pipeline.

For multi-account users where the deeplink doesn't specify which account it's pairing under, `DeeplinkAccountPicker` (existing) prompts for an account and then proceeds to `ApprovalSheet`. That flow is unchanged.

#### Empty bunker URI (no signer key yet)

If `appState.bunkerURI` is empty (rare — would mean no key has been imported), the Bunker tab shows a placeholder: "No signer key imported yet — add an account in Settings to generate a bunker URI." The QR + URI card both hide; the action row (Copy / New secret) is disabled. The Nostrconnect tab works regardless since it doesn't depend on a signer key existing.

In practice this state shouldn't be reachable from the user-facing flow (the connect button only shows when an account exists), but the safety check costs nothing.

## Implementation file mapping

### Modified

- `Clave/Views/Home/Connect/ConnectSheet.swift` — rewritten. Drops `ConnectMethod` enum, `path: [ConnectMethod]` state, `methodCards` view, `headerBlock` (no longer needed). Adds `selectedTab: Tab` state (defaulting to `.bunker`), the segmented control, and the tab body switch. Existing `parsedURI`, `isConnecting`, `connectionError`, `handleParsed`, `submitApproval` stay unchanged. The `connectingOverlay` and `Connection Failed` alert stay unchanged.
- `Clave/Views/Home/HomeView.swift` — `emptyClientsView` icon swap: `Label("Connect a Client", systemImage: "plus.circle.fill")` → `Label("Connect a Client", systemImage: "plus")`. **Already applied as part of this brainstorm.** Comment added explaining the negative-space rendering issue.

### Added

- `Clave/Views/Home/Connect/ConnectBunkerTabView.swift` — new file, ~80-100 lines. Body of the Bunker tab. Owns the QR generation (extracted from `ConnectShowQRView`), the URI text section, the action row. Carries forward the `copiedBunker`/`@State` toggle + 2-second revert. Carries forward the `showQR` full-screen presentation.
- `Clave/Views/Home/Connect/ConnectNostrconnectTabView.swift` — new file, ~120-150 lines. Body of the Nostrconnect tab. Composes the existing camera scanner (refactored as a child view) + paste field + help link. Owns the help-sheet presentation state.
- `Clave/Views/Home/Connect/ConnectHelpSheet.swift` — new file, ~40-60 lines. The "What's a nostrconnect URI?" explanatory sheet. Static content, single button to dismiss. Uses `presentationDetents([.medium])`.

### Deleted

- `Clave/Views/Home/Connect/ConnectMethodCard.swift` — no longer needed (no method chooser).
- `Clave/Views/Home/Connect/ConnectShowQRView.swift` — content absorbed into `ConnectBunkerTabView`.
- `Clave/Views/Home/Connect/ConnectScanQRView.swift` — content absorbed into `ConnectNostrconnectTabView` (or extracted as a sub-component if the camera logic is reused elsewhere — verify during implementation).
- `Clave/Views/Home/Connect/ConnectPasteView.swift` — paste functionality inlined into `ConnectNostrconnectTabView`.

### Unchanged

- `Clave/Views/Home/Connect/ConnectAccountContextBar.swift` — still rendered above the tab body in the new layout.
- `Clave/Views/Home/Connect/DeeplinkAccountPicker.swift` — used by `DeeplinkRouter`, separate flow.
- `Shared/NostrConnectParser.swift` — unchanged.
- `Clave/AppState.swift` `handleNostrConnect` / `bunkerURI` / `rotateBunkerSecret` — unchanged.

## Bonus: HomeView empty-state CTA — icon fix + AccountTheme tint

Two changes to `emptyClientsView` in `Clave/Views/Home/HomeView.swift`. Part 1 (icon swap) was already applied to the working tree during brainstorm; part 2 (tint) gets applied alongside the ConnectSheet redesign.

### Part 1 — icon glyph swap (already applied)

```diff
- Label("Connect a Client", systemImage: "plus.circle.fill")
+ Label("Connect a Client", systemImage: "plus")
```

Cause: `plus.circle.fill` is a filled SF Symbol where the plus glyph is **negative space** punched through the filled circle. In monochrome rendering on a `.borderedProminent` button, the filled circle picks up the foreground tint while the plus shows the button background through. When those two colors are similar (which happens with the system default tint pair against the AccountTheme's accent), the entire icon becomes invisible. The simple `plus` glyph has no negative space — it always renders as a contrasting glyph on the button background.

### Part 2 — tint the prominent button to AccountTheme.accent

`emptyClientsView` should compute `theme = AccountTheme.forAccount(pubkeyHex: appState.currentAccount?.pubkeyHex ?? "")` at the top (matching the pattern in the existing `pairNewConnectionButton` builder), then apply `.tint(theme.accent)` to the button. This makes the empty-state primary CTA visually consistent with the smaller `Pair New Connection` row that already uses `theme.accent`-themed fill+foreground. Both surfaces represent the same action ("add a client connection") and should share the per-account identity color.

```diff
- private var emptyClientsView: some View {
-     HStack {
-         Spacer()
-         VStack(spacing: 16) {
+ private var emptyClientsView: some View {
+     let theme = AccountTheme.forAccount(pubkeyHex: appState.currentAccount?.pubkeyHex ?? "")
+     return HStack {
+         Spacer()
+         VStack(spacing: 16) {
              ...
              Button { handlePairNewConnectionTap() } label: {
                  Label("Connect a Client", systemImage: "plus")
                      .font(.body.bold())
                      .frame(maxWidth: .infinity)
              }
              .buttonStyle(.borderedProminent)
+             .tint(theme.accent)
              .padding(.horizontal, 32)
          }
          .padding(.vertical, 40)
          Spacer()
      }
  }
```

After this change, the empty-state CTA inherits the active account's gradient color — the button fill matches the account strip pill on Home, the small Pair New Connection button below the clients list, and the avatar ring. Switching active accounts updates the CTA color in lockstep with the rest of the per-account chrome.

## Verification (manual test plan, post-implementation)

1. **Bunker tab default + tap-to-copy.** Open ConnectSheet from HomeView's "Pair New Connection." Default tab is Bunker. QR is visible; URI text is visible below the QR with a "Bunker URI" header. Tap the QR — clipboard contains the bunker URI; haptic fires; button briefly shows "Copied". Tap the URI text card — same behavior.
2. **New secret rotation.** Tap "New secret" — the QR + URI text both update to reflect the new secret. Verify by comparing pre/post URI text.
3. **Switch to Nostrconnect tab.** Camera permission prompt appears (first time). Allow → live viewfinder renders. Below it: paste field + help link.
4. **Scan flow.** Show a `nostrconnect://` QR (from clave.casa or any web client) at the camera. Detected → `ApprovalSheet` presents → existing approval flow.
5. **Paste flow.** Copy a `nostrconnect://` URI from clipboard. Tap into the paste field, paste, hit Done. `ApprovalSheet` presents. Same flow as scan.
6. **Invalid paste.** Type "not a uri" into the paste field, hit Done. Field shows red error border + caption. Approval flow doesn't trigger.
7. **Help link.** Tap "ⓘ What's a nostrconnect URI?" — explanatory sheet presents at medium detent. Read copy. Dismiss.
8. **Camera denied path.** Settings → Privacy → Camera → revoke Clave. Reopen ConnectSheet → Nostrconnect tab. Viewfinder shows "Camera access denied" placeholder + "Open Settings" link. Paste field still works.
9. **Empty-state CTA.** With no clients connected, HomeView shows the empty state. The "Connect a Client" button now has a visible plus glyph and its fill matches the active account's `theme.accent` color (verify by switching active accounts via the Home strip — CTA color updates in lockstep). Tap it → ConnectSheet presents per the above.
10. **Deeplink path bypasses sheet.** Open clave.casa Sign In QR → scan with iOS camera (system camera, not Clave) → tap notification → Clave opens directly into ApprovalSheet, NOT ConnectSheet. Confirms `DeeplinkRouter` continues to bypass.
11. **Multi-account context bar.** With 2+ accounts, ConnectAccountContextBar renders above the tab body and shows the active account name + avatar. Switching the active account elsewhere reflects in this bar.

## Out of scope / follow-ups

- **Bunker tab — long URI overflow handling.** `lineLimit(3)` truncates with ellipsis. If users frequently have URIs that get truncated, consider switching to a scrollable text view. Track if it surfaces as a real complaint.
- **Help-sheet copy A/B testing.** The drafted copy is a first pass. Worth iterating after a few users have read it.
- **"Bunker QR" / "Scan / Paste URI" hybrid labels** (Option C from the brainstorm) — if "Bunker" / "Nostrconnect" jargon turns out to confuse non-technical users despite the help link, fall back to hybrid labels in a follow-up sprint.

## Sequencing + branch hygiene

The repo currently has uncommitted parallel WIP for the approve-pending UX redesign sprint (per HANDOFF.md, ~12 modified files including `Clave/Views/Home/HomeView.swift`). The HomeView icon fix was applied to the working tree directly because the WIP doesn't touch `emptyClientsView`. The ConnectSheet redesign should land on its own feature branch off the same WIP base — implementer can choose whether to bundle with the approve-pending work or split into a separate PR.

Implementation effort estimate: ~1 day for code + tests + manual verification on a real device. Light bug-fix complexity, mostly UI restructuring.
