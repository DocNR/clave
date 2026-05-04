# ConnectSheet Redesign + Nostrconnect Integration

**Date:** 2026-05-02
**Status:** Brainstorming complete; awaiting plan
**Sprint:** ConnectSheet design-system pass on `feat/multi-account`
**Builds on:** [Design System](../../design-system.md) (just shipped on `b950cc2`); [Stage C Home Redesign](2026-05-02-stage-c-home-redesign-design.md)

## Context

Current `ConnectSheet` (`Clave/Views/Home/ConnectSheet.swift`) shows two parallel options stacked in a ScrollView: a "Bunker Address" section and a "Or paste a nostrconnect:// URI" section. The nostrconnect path is dev-menu-gated (`if devSettings.nostrconnectEnabled`). The visual treatment uses `Color(.systemGray6)` cards — pre-design-system styling that doesn't match the Home redesign's identity-zone-vs-functional-zone language.

Three changes drive this redesign:

1. **Apply the design system** — drop `systemGray6` boxes, use theme-aware accents, match the Home tab's polish level.
2. **Officially integrate Nostrconnect** — it has been working reliably in dev-gated form; remove the gate and make it an equal-citizen connection method.
3. **Add camera QR scanning** — currently Clave only *shows* QRs (for clients to read); it can't *read* a Nostrconnect QR from a web client on a different device. AVFoundation viewfinder + parse-on-detection.

Plus two architectural decisions:

4. **Register URL schemes** — `nostrconnect://` (NIP-46 standard) + `clave://` (reserved namespace for first-party deep links). iOS opens Clave when a Nostrconnect URL is tapped anywhere in the system.
5. **Multi-account binding for incoming deeplinks** — auto-bind to current account when there's only one, account picker when there are multiple.

## Goals

- ConnectSheet becomes a clear "pick a method" entry point that maps to user mental models.
- Three connection methods (Show my QR / Scan QR / Paste Nostrconnect) are equal in visibility; users pick the one that matches their context.
- Camera QR scan unlocks the cross-device flow that was previously impossible (web client on laptop ↔ Clave on phone).
- Tapping a `nostrconnect://` link in Safari, Messages, or any other iOS app opens Clave directly and arrives at the security gate (ApprovalSheet) with one tap.
- Per-account theming carries through every connect surface so the user always knows which identity is being connected.

## Non-goals

- Not redesigning ApprovalSheet itself (touched separately if needed).
- Not redesigning ClientDetailView or other connection-related surfaces.
- Not implementing Universal Links via `clave.casa` (deferred until the domain is deployed).
- Not implementing `clave://` deep-link handlers (registered but reserved — no concrete actions yet).
- Not changing the bunker URI format, secret rotation behavior, or NIP-46 wire protocol.
- Not adding QR generation features beyond what already exists (`QRCodeView`).

## Locked design decisions

Captured during brainstorming session at `~/clave/Clave/.superpowers/brainstorm/81180-1777760291/`.

| Decision | Choice |
|---|---|
| ConnectSheet layout | **Three method cards** (Approach A) — each card pushes a focused view via NavigationStack |
| Method card copy style | **V2 tightened** — title + dim parens for technical term + descriptive subtitle (no client name-drops) |
| Method card icons | 56pt rounded-rect with theme-style gradient (purple/violet for bunker, teal/aqua for scan, coral/pink for paste) |
| Account context bar | Top of every focused view — mini themed dot (matches account's `theme.start→theme.end`) + "Connecting to @petname" caption |
| Show my QR view | Big QR centered + monospaced bunker URI underneath + Copy + New Secret buttons + single-use note |
| Scan QR view | Full-bleed dark camera viewfinder + corner brackets in `theme.accent` + "Paste link" fallback in caption |
| Paste view | Textfield + "Paste from clipboard" helper + Connect button |
| URL schemes | **`nostrconnect://` + `clave://`** registered now. `clave://` reserved (no handlers). Universal Links via `clave.casa` deferred. |
| Deeplink arrival flow | Direct to ApprovalSheet (no intermediate confirmation) |
| Multi-account binding for deeplink | Auto-bind to current if 1 account; account picker if 2+ |
| Account picker style | Sheet with strip-pill-style cards (reuses AccountTheme + AvatarView treatments from design system) |
| Camera permission | First-use system prompt via `AVCaptureDevice.requestAccess(for: .video)`. Denied state shows "Open Settings" link inline. |
| Sheet treatment | `.presentationBackground(Color(.systemGroupedBackground))` (already shipped 2026-05-02 on `1a06290`); `.presentationDetents([.large])` |

## Files in scope

**New files:**
- `Clave/Views/Home/Connect/ConnectSheet.swift` — entry view (replaces existing `Clave/Views/Home/ConnectSheet.swift`; moved into a `Connect/` subfolder)
- `Clave/Views/Home/Connect/ConnectShowQRView.swift` — focused bunker QR view
- `Clave/Views/Home/Connect/ConnectScanQRView.swift` — focused camera scanner view
- `Clave/Views/Home/Connect/ConnectPasteView.swift` — focused paste view
- `Clave/Views/Home/Connect/ConnectMethodCard.swift` — reusable card component (icon + title + dim-parens-term + subtitle + chevron)
- `Clave/Views/Home/Connect/ConnectAccountContextBar.swift` — reusable "Connecting to @x" bar at top of each focused view
- `Clave/Views/Components/QRScannerView.swift` — UIViewRepresentable wrapper around AVCaptureSession (reusable; not Connect-specific)
- `Clave/Views/Home/Connect/DeeplinkAccountPicker.swift` — sheet for selecting account when multi-account deeplink arrives

**Modified files:**
- `Clave/Info.plist` — add `CFBundleURLTypes` (nostrconnect, clave) + `NSCameraUsageDescription`
- `Clave/ClaveApp.swift` — `.onOpenURL { ... }` handler routing to AppState
- `Clave/AppState.swift` — new `pendingNostrconnectURI: NostrConnectParser.ParsedURI?` published state (analogous to `pendingDetailPubkey`); new `pendingDeeplinkAccountChoice: NostrConnectParser.ParsedURI?` for multi-account picker case
- `Clave/Views/Home/HomeView.swift` — observe `appState.pendingNostrconnectURI` to present ApprovalSheet directly; observe `pendingDeeplinkAccountChoice` to present DeeplinkAccountPicker
- `Clave/Views/Home/ApprovalSheet.swift` — accept an optional `boundAccountPubkey: String?` param so deeplink-arrived URIs are bound to the chosen account, not implicitly current
- `Clave/Views/Settings/DeveloperSettings.swift` — drop `nostrconnectEnabled` flag (or repurpose for some other dev gate)

**Deleted:**
- `Clave/Views/Home/ConnectSheet.swift` — replaced by `Connect/ConnectSheet.swift`

## Architecture

### Component tree

```
ConnectSheet
├── ConnectMethodCard × 3 (Show my QR / Scan / Paste)
│   ├── pushes ConnectShowQRView
│   ├── pushes ConnectScanQRView
│   └── pushes ConnectPasteView
└── all three views:
    ├── ConnectAccountContextBar at top
    └── their own action area (QR / camera / textfield)

App-level:
ClaveApp
└── .onOpenURL { url in handleDeeplink(url) }
    ├── nostrconnect:// → parse → set appState.pendingDeeplinkAccountChoice (multi-account) OR pendingNostrconnectURI (single)
    └── clave://         → reserved, log + ignore for now

HomeView
├── observes appState.pendingDeeplinkAccountChoice → presents DeeplinkAccountPicker
└── observes appState.pendingNostrconnectURI → presents ApprovalSheet(parsedURI:, boundAccountPubkey:)
```

### Type changes

```swift
// AppState additions
var pendingNostrconnectURI: NostrConnectParser.ParsedURI?       // direct ApprovalSheet trigger
var pendingDeeplinkAccountChoice: NostrConnectParser.ParsedURI? // picker trigger; cleared after pick
var deeplinkBoundAccount: String?                                // account chosen for the in-flight deeplink

// ApprovalSheet signature change
init(parsedURI: NostrConnectParser.ParsedURI,
     boundAccountPubkey: String? = nil,        // NEW — explicit binding from deeplink
     onApprove: @escaping (...) -> Void)
```

`boundAccountPubkey == nil` means "use current account" (existing behavior — preserved for ConnectSheet's manual-paste path). `boundAccountPubkey != nil` means "bind to this specific account" (deeplink-arrived path).

## Data flow

### Manual paths (user opens ConnectSheet)

```
HomeView "Pair New Connection" tap
  → handlePairNewConnectionTap (cap pre-check)
  → showConnectSheet = true
  → ConnectSheet root with three method cards
  → user taps a card → NavigationLink push to focused view
    → focused view collects URI / generates URI / scans QR
    → on success: parse → set local @State parsedURI (or call back to ConnectSheet)
    → ConnectSheet presents ApprovalSheet with parsedURI
    → ApprovalSheet uses currentAccount (boundAccountPubkey == nil)
```

### Deeplink path (single-account)

```
User taps nostrconnect://... in Safari/Messages
  → iOS opens Clave (URL scheme handler)
  → ClaveApp.onOpenURL fires
  → NostrConnectParser.parse(uri)
  → if appState.accounts.count == 1:
      → appState.pendingNostrconnectURI = parsedURI
  → HomeView .onChange(of: pendingNostrconnectURI):
      → present ApprovalSheet(parsedURI: parsed, boundAccountPubkey: nil)
      → ApprovalSheet uses currentAccount (which is the only account)
      → on approve: existing handleNostrConnect path; on dismiss: clear pendingNostrconnectURI
```

### Deeplink path (multi-account)

```
User taps nostrconnect://... in Safari/Messages
  → iOS opens Clave
  → ClaveApp.onOpenURL fires
  → NostrConnectParser.parse(uri)
  → if appState.accounts.count >= 2:
      → appState.pendingDeeplinkAccountChoice = parsedURI
  → HomeView .onChange(of: pendingDeeplinkAccountChoice):
      → present DeeplinkAccountPicker(parsedURI:, accounts: appState.accounts)
      → user taps an account card
      → picker dismisses, sets:
          appState.pendingNostrconnectURI = parsedURI
          appState.deeplinkBoundAccount = pickedPubkey
          appState.pendingDeeplinkAccountChoice = nil
      → HomeView's other onChange fires:
          → present ApprovalSheet(parsedURI:, boundAccountPubkey: pickedPubkey)
          → on approve: handleNostrConnect threads boundAccountPubkey through to AppState
```

`AppState.handleNostrConnect` already exists; it currently uses `currentAccount` implicitly. The change: accept an optional `accountPubkey` param, fall back to current if nil.

### Show my QR data flow

```
ConnectShowQRView.onAppear:
  → bunkerURI = appState.bunkerURI  // already exists
  → render QR via existing QRCodeView
User taps Copy:
  → UIPasteboard.general.setItems(...)  // existing 120s expiration logic
User taps New secret:
  → appState.rotateBunkerSecret()  // existing
  → bunkerURI re-renders with new secret
```

### Scan QR data flow

```
ConnectScanQRView.onAppear:
  → AVCaptureDevice.requestAccess(for: .video) { granted in ... }
  → granted: start AVCaptureSession with AVCaptureMetadataOutput (qr objectType)
  → denied: show "Open Settings" inline view + "Paste link" fallback
QRScannerView delegate fires on QR detection:
  → metadataObject.stringValue → NostrConnectParser.parse(_:)
  → success: stop session, set parsedURI on parent ConnectSheet → ApprovalSheet
  → invalid scheme / parse error: brief inline error toast, keep scanning
```

### Paste data flow

```
ConnectPasteView text input:
  → "Paste from clipboard" tap → reads UIPasteboard.general.string
  → Connect button enabled when input non-empty
  → on tap: NostrConnectParser.parse → set parsedURI on parent → ApprovalSheet
```

## Camera permission handling

- **First use:** `AVCaptureDevice.authorizationStatus(for: .video)` → `.notDetermined` → call `requestAccess` → on grant, start session; on deny, fall to denied state.
- **Already granted:** start session immediately.
- **Already denied:** show inline view with explanation + "Open Settings" button (`UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)`). Below it: "Or paste a Nostrconnect link" link to the Paste view (without dismissing the sheet).
- **Restricted (parental controls):** treat as denied with copy mentioning the restriction.
- **Simulator (no camera):** show a placeholder "Camera unavailable in simulator" message + Paste link fallback.

`Info.plist` `NSCameraUsageDescription`: *"Clave uses the camera to scan Nostrconnect QR codes from web clients so you can sign events without typing long URLs."*

## URL scheme registration

`Info.plist` additions:

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLName</key>
        <string>com.docnr.clave.nostrconnect</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>nostrconnect</string>
        </array>
    </dict>
    <dict>
        <key>CFBundleURLName</key>
        <string>com.docnr.clave.clave</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>clave</string>
        </array>
    </dict>
</array>
```

`ClaveApp.swift` handler:

```swift
.onOpenURL { url in
    switch url.scheme {
    case "nostrconnect":
        handleNostrconnectDeeplink(url: url)
    case "clave":
        // Reserved namespace — log + ignore for now.
        // Future: clave://open-detail/<pubkey>, clave://switch-account/<pubkey>, etc.
        logger.notice("[Deeplink] clave:// received but no handler: \(url.absoluteString)")
    default:
        break
    }
}
```

## Account context bar (`ConnectAccountContextBar`)

Reusable subview shown at the top of all three focused views:

```
[●●] Connecting to @alice
```

- 14pt circle filled with `LinearGradient(theme.start, theme.end)` + 1.5pt `theme.start` border (matches strip pill in miniature)
- 12pt monospaced-or-system-secondary text "Connecting to @<displayLabel>"
- 8pt vertical / 16pt horizontal padding
- Sits above the focused content; never tappable

Account is resolved from `appState.currentAccount` (manual paths) — these focused views never run for multi-account-deeplink arrivals; deeplinks skip ConnectSheet entirely.

## Account picker for multi-account deeplinks (`DeeplinkAccountPicker`)

Sheet presentation, `.presentationDetents([.medium])`, `.presentationBackground(Color(.systemGroupedBackground))`.

Layout:
- Header: "Connect with which account?"
- Subhead: "Choose the identity to use for `<client name from URI, or "this connection">`."
- Vertical list of account cards (top-to-bottom; works cleanly at the 4-account cap; revisit if cap rises and grid layout becomes warranted), each:
  - 60pt avatar (cached PFP if available, else AvatarView pubkey-hue placeholder)
  - 4pt active-style gradient ring on the *current* account (so user can quickly stick with it)
  - `@displayLabel` below
  - Tap fires picker callback
- Cancel button dismisses the picker AND clears `pendingDeeplinkAccountChoice` (deeplink discarded; user must re-tap the link to retry)

Reuses tokens from the design system: AccountTheme palette, AvatarView, displayLabel rule.

## Error handling

| Scenario | Behavior |
|---|---|
| Nostrconnect URI fails to parse (paste / scan / deeplink) | Inline red error message with `NostrConnectParser.ParseError` cases (existing copy: "URI must start with nostrconnect://", etc.). Scan flow keeps the camera running; paste flow keeps the user on the screen. Deeplink-arrival parse failure logs + drops silently (no UI; user can re-initiate from the client). |
| Camera permission denied | Inline view inside ConnectScanQRView with "Open Settings" + "Paste link" fallback. Never auto-dismisses. |
| Camera unavailable (simulator) | Placeholder message + "Paste link" fallback. |
| Cap reached (5 clients) on connect attempt | Existing ApprovalSheet pre-check + alert (per design-system cap pre-check pattern). Deeplink path also routes through ApprovalSheet so the same alert fires. |
| Bunker URI generation fails (rare; AppState always has one for current account) | Show inline error in ConnectShowQRView + Retry button. |
| Multi-account deeplink with `accounts.count == 0` | Should never happen (no accounts means no Home view). Defensive: log + drop. |

## Testing

**Unit tests:**
- `NostrConnectParserTests` already exists; reuse.
- New `DeeplinkRouterTests` (or add to existing parser tests): given a `nostrconnect://` URL, verify the AppState state transitions for both single-account and multi-account cases.
- New: `ConnectAccountContextBarTests` to verify `displayLabel` resolution + theme color application.

**Manual verification:**
- All three focused views render correctly in light + dark mode.
- Account context bar updates when user switches accounts (long-press scenario inside ConnectSheet — should never happen because ConnectSheet only opens against current, but defensive check).
- Camera permission first-use flow on a fresh install.
- Scan a Nostrconnect QR from a web client (Coracle / zap.cooking) on a desktop browser — verify Clave reads, parses, presents ApprovalSheet.
- Paste a Nostrconnect URI from clipboard — verify parse + ApprovalSheet.
- Tap a `nostrconnect://` link in Safari / Messages → Clave opens → ApprovalSheet (single-account) or DeeplinkAccountPicker (multi-account).
- Tap `clave://anything` → Clave opens, no UI surfaces (logged + ignored).
- Re-archive: ensure Info.plist URL scheme entries are present in shipped IPA.

## Implementation phasing

The work is medium-sized for a single sprint. Recommended phases (each shippable independently):

**Phase 1 — Visual redesign + de-gate (~1-2 days)**
- New ConnectSheet entry view with three method cards
- Move existing bunker section into ConnectShowQRView
- Move existing nostrconnect paste section into ConnectPasteView (un-gated)
- Account context bar component
- Apply design system tokens
- ConnectScanQRView placeholder (shows "Coming soon" — wired but no camera yet)
- Build + verify on device; this is shippable as-is and removes the dev-gate visibility issue

**Phase 2 — Camera QR scan (~2-3 days)**
- `QRScannerView` (UIViewRepresentable + AVFoundation)
- ConnectScanQRView wired to QRScannerView
- Camera permission handling
- `NSCameraUsageDescription` in Info.plist
- Manual test against real Nostrconnect QRs from web clients
- Phase 2 archive: build for internal TF, smoke test

**Phase 3 — Deeplink routing (~1 day)**
- Info.plist URL scheme registration
- ClaveApp.onOpenURL handler
- AppState `pendingNostrconnectURI` + `pendingDeeplinkAccountChoice` state
- HomeView observers
- DeeplinkAccountPicker
- ApprovalSheet `boundAccountPubkey` param
- Manual test: nostrconnect:// link from Safari / Messages → ApprovalSheet

Total estimated: 4-6 days. Could also ship as one combined commit if the user prefers a single archive over staged TF builds.

## Out of scope (deferred)

- Universal Links via `clave.casa` (defer until clave.casa apex is deployed; will arrive as a third channel alongside the two URL schemes).
- `clave://` concrete handlers (`clave://open-detail/<pubkey>`, `clave://switch-account/<pubkey>`, etc.) — register the scheme now, design specific actions when there's a real consumer.
- ConnectedClient row creation in bunker connect path (pre-existing gap from polish backlog — separate issue, doesn't block ConnectSheet redesign).
- ApprovalSheet visual redesign (handled separately if needed).
- Camera flash toggle on the scan view (YAGNI for v1).
- Scan-from-photo-library (YAGNI — scan from camera covers most cases; paste covers the rest).
- Account picker for *manual* paths (current account is implicit by design — same pattern as Stage C).
- **Bunker pair-time permission UX** — explicitly deferred to a separate sprint. The bunker pathway in `LightSigner.swift` hardcodes `trustLevel: .medium` + `kindOverrides: [:]` because the NSE has no foreground UI affordance; nostrconnect pairs via ApprovalSheet get full granular control. Asymmetry has both UX and security implications (bunker-paired client gets `.medium` allow-list across common kinds without user per-kind review). Foreground-aware promotion or deferred-approval are options. Risk of regressing the working bunker flow is high enough that this redesign sprint preserves current bunker behavior and addresses the asymmetry separately. Tracked in sprint memory `stage-c-sprint.md` polish backlog.

## References

- Brainstorm session: `~/clave/Clave/.superpowers/brainstorm/81180-1777760291/`
  - `connectsheet-structure-v1.html` — three structural variants (locked: A, three method cards)
  - `copy-variants-v1.html` — V1 user proposed vs V2 tightened (locked: V2)
  - `focused-views-v1.html` — three focused views (locked: design as shown)
- Design system: [`docs/design-system.md`](../../design-system.md)
- Stage C Home Redesign spec: [`2026-05-02-stage-c-home-redesign-design.md`](2026-05-02-stage-c-home-redesign-design.md)
- Existing Connect code: `Clave/Views/Home/ConnectSheet.swift`
- Existing parser: `Shared/NostrConnectParser.swift`
- Existing QR display: `Clave/Views/Components/QRCodeView.swift`
- AVFoundation QR scanning reference: Apple's [AVCaptureMetadataOutput docs](https://developer.apple.com/documentation/avfoundation/avcapturemetadataoutput)
