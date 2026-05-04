# AccountDetailView Redesign + Pair-New-Connection Polish

**Date:** 2026-05-03
**Status:** Brainstorming complete; awaiting plan
**Sprint:** AccountDetailView design-system pass on `feat/multi-account` (last UX work before v0.2.0-build45 external promotion)
**Builds on:** [Design System](../../design-system.md); [Stage C Multi-Account UX](2026-05-01-stage-c-multi-account-ux-design.md); [Stage C Home Redesign](2026-05-02-stage-c-home-redesign-design.md); [ConnectSheet Redesign](2026-05-02-connectsheet-redesign-design.md)

## Context

Current `AccountDetailView` (`Clave/Views/Settings/AccountDetailView.swift`) shipped during Stage C as a Form with a banner Section header + four content Sections (Petname / Profile / Security / Delete). It is functionally complete (all five behavioral contracts work) but its visual treatment predates both the design-system doc and the ConnectSheet redesign. Side-by-side with the new ConnectSheet and the polished Home tab, it reads like a different app — flat banner, default Form chrome, ALL-CAPS small grey section headers, no continuity with the per-account identity language Home now establishes.

Two smaller Home-tab follow-ups fold into the same sprint because they share design-system territory and ride into the same external build:

1. **Pair-New-Connection row** in HomeView's Connected Clients section uses the same row chrome as a `ConnectedClient` row (32pt icon circle + bold subheadline + caption subtitle + chevron). At a glance it reads as data, not as an action — users miss it as the entry point for adding a new client.
2. **Profile-edit gap** — Clave iOS users today have no way to edit their kind:0 profile from inside Clave. The clave.casa web companion (sibling project) exists for exactly this purpose, but the integration handoff from iOS has not been wired. AccountDetailView is the natural surface for this link since it's already where users see the profile data.

This spec is the last UX work before the v0.2.0-build45 external promotion. After it lands cleanly: URL revert + pbxproj/MARKETING_VERSION bump → archive → external.

## Goals

- AccountDetailView visually rhymes with Home — the user feels like they are "drilling deeper into" the active-account identity zone, not jumping to a separate settings screen.
- Profile section becomes informationally rich — `about`, `nip05`, `lud16`, paired-clients count — closing the "is this the right account?" recognition gap when users have several accounts.
- Pull-to-refresh replaces the explicit Refresh button (matches Home and iOS conventions; reduces row weight in the Profile section).
- Pair-New-Connection row is unmistakably an action at first glance.
- Clave iOS gains a one-tap path to edit the kind:0 profile via clave.casa, with the bunker URI prebound so the editing experience is "tap → make changes → tap Approve in Clave" with no manual pairing for already-paired browsers.
- Per-account theming carries through every redesigned surface so the active-account signal stays consistent.

## Non-goals

- Not changing AccountDetailView's information architecture beyond the new Profile rows (sections stay in order: Petname → Profile → Security → Delete).
- Not adding switch-account affordances on AccountDetailView. Switching is exclusively a Home affordance.
- Not refactoring `ExportKeySheet` to accept a pubkey parameter — the current-account-only gate stays.
- Not changing the bunker pair-time permission UX (separate sprint for the `LightSigner.swift:172-184` `.medium`-hardcoded asymmetry).
- Not redesigning `PendingApprovalsView` (Phase D in the rollout plan; deferred to a dedicated session post-rollout).
- Not changing `ConnectedClient` row visual treatment.
- Not adding live `nip05` verification (would need `.well-known/nostr.json` fetches; defer to a later release — display the string as-is).
- Not adding the marketing landing page or AASA file on clave.casa side (parallel clave.casa session owns; tracked in `~/clave-casa/BACKLOG.md`).
- Not implementing Universal Links iOS-side wiring for `applinks:clave.casa` (Phase B in the rollout plan; coordinated with clave.casa AASA deployment, separate scope from this spec).

## Locked design decisions

Captured during brainstorming session at `~/clave/Clave/.superpowers/brainstorm/83961-1777779518/`.

### AccountDetailView

| Decision | Choice |
|---|---|
| Structural direction | **C — Identity-zone banner + ambient gradient Form (Home idiom).** Banner extends the active-account theme gradient; Form sits on Home's ambient gradient with `.scrollContentBackground(.hidden)` + `.listRowBackground(Color.clear)`. |
| Banner content | Avatar (56pt, treatment A if PFP cached, treatment C otherwise) + `displayLabel` + truncated npub + copy button. Same content as today; design-doc §5.5 dimensions (18/22 padding). |
| Section headers | Sentence-case `.headline` + `.textCase(nil)` (matches Home's "Connected Clients"). No ALL-CAPS small grey. |
| Section order | Petname → Profile → Security → Delete. Unchanged. |
| Profile section content | Display name · About · NIP-05 · Lightning · "N paired clients" stat · Edit on clave.casa. Each conditional on data except paired-clients (always shown, even at 0) and Edit-on-clave.casa (always shown). |
| About row | Stacked block (label above, multi-line text below), `.lineLimit(2)` default with tap-to-expand toggle. Toggle pill ("Show more" / "Show less") only renders if text actually overflows two lines. |
| Refresh | **Pull-to-refresh** via `.refreshable { await appState.refreshProfile(for: pubkeyHex) }` on the Form. No explicit Refresh button row. |
| Switch-account affordance | None. AccountDetailView is read-only with respect to current-account state. |
| Security section | Rotate bunker secret + Export private key (current account only). Unchanged behavior. |
| Delete section | Destructive button + named alert (`"Delete @<name>?"`) + connection-count footer. Unchanged. |
| Conditional rendering | Empty `about` / `nip05` / `lud16` hide their rows. The "Paired clients" stat is always visible (even at 0). |

### Pair-New-Connection row

| Decision | Choice |
|---|---|
| Treatment | **Option C — HIG inline action.** 22pt tinted plus circle (`theme.accent.opacity(0.18)` background + `theme.accent` glyph) + accent-color label, no chevron, no subtitle. Native iOS pattern (Mail "Add Mailbox", Settings "Add Account"). |
| Placement | Top of Connected Clients section. Unchanged. |
| Color | `theme.accent` (per-account) for plus glyph + label. Identity continuity with the active account. |
| Tap behavior | Unchanged. Cap pre-check (5 connections) → opens `ConnectSheet`. |

### clave.casa profile-edit handoff

| Decision | Choice |
|---|---|
| Surface | "Edit on clave.casa" row in AccountDetailView's Profile section (last row, with `↗` outbound icon). Always visible. |
| URL shape | `https://clave.casa/edit#bunker=<URL-encoded-bunker-uri>` (Option B — fragment-prebound). Fragment never reaches a server; clave.casa parses it and either re-uses the existing pairing for that signer pubkey or pairs fresh. |
| Tap behavior | `UIApplication.shared.open(url)` (or `Link(url)`). Routes through Safari → clave.casa. |
| Phase B interaction | `applinks:clave.casa` AASA is scoped tightly to `/connect/?uri=*`; `/edit#bunker=...` is intentionally **not** claimed by Clave iOS, so this link always routes to Safari/clave.casa and never bounces back to Clave. |

## Files in scope

**Modified files:**

- `Clave/Views/Settings/AccountDetailView.swift` — full redesign per the locked decisions above.
- `Clave/Views/Home/HomeView.swift` (`pairNewConnectionRow` + `pairNewConnectionIcon` + `pairNewConnectionLabel` private vars, lines 321-357) — replace icon-circle row with HIG inline action.
- `Clave/Shared/SharedModels.swift` — extend `CachedProfile` struct with three optional fields:
  ```swift
  struct CachedProfile: Codable, Equatable {
      var displayName: String?
      var pictureURL: String?
      var about: String?      // NEW
      var nip05: String?      // NEW
      var lud16: String?      // NEW
      var fetchedAt: Double
  }
  ```
  Codable handles missing keys; no migration needed (same pattern as PR #19's `ActivityEntry` extension).
- `Clave/AppState.swift` (`fetchProfile(for:)` and supporting JSON parser) — extend kind:0 JSON extraction to populate `about`, `nip05`, `lud16` (in addition to existing `display_name`/`name` and `picture`).
- `Clave/Shared/SharedConstants.swift` — add `claveCasaEditBaseURL: String = "https://clave.casa/edit"` constant for the link target.

**New files:**

- `Clave/Views/Settings/AccountDetailAboutBlock.swift` (or inline private struct in AccountDetailView) — reusable About block with `lineLimit` toggle + overflow detection.

**Tests:**

- `ClaveTests/CachedProfileTests.swift` — Codable round-trip with new fields present + missing (no migration). `5` tests target.
- `ClaveTests/SharedModelsTests.swift` — extend if exists; otherwise above file covers.

## Architecture

### Component tree

```
AccountDetailView (NavigationDestination)
├── .refreshable { await appState.refreshProfile(for: pubkeyHex) }
├── .scrollContentBackground(.hidden)
├── HomeView's ambient gradient (re-derived from current account theme)
└── Form
    ├── Section { EmptyView() } header: { bannerHeader }   // full-bleed banner
    ├── Section "Petname" { TextField + Save }
    ├── Section "Profile"
    │   ├── kv-row Display name (conditional)
    │   ├── about-block About (collapsible, conditional)
    │   ├── kv-row NIP-05 (conditional)
    │   ├── kv-row Lightning (conditional)
    │   ├── stat-row "N paired clients" (always)
    │   └── action-row "Edit on clave.casa ↗" (always)
    ├── Section "Security"
    │   ├── action-row Rotate bunker secret
    │   └── action-row Export private key (current-account only)
    └── Section { destructive Delete button } footer: { connection-count copy }

HomeView's Connected Clients section (modified)
└── Section
    ├── pairNewConnectionRow  (Option C: HIG inline action)
    ├── ConnectedClient row × N
    └── ...
```

### Data flow

```
AppState.refreshProfile(for: pubkeyHex)
  → AppState.fetchProfile(for: pubkeyHex)  [private async]
    → SimplePool fan-out to NIP-65 read relays
    → kind:0 event → JSON parse
    → extract: display_name, name, picture, about, nip05, lud16   ← extended
    → cacheImage(from: pictureURL, pubkey:) before mutation       ← existing order, don't regress
    → MainActor: accounts[idx].profile = CachedProfile(...)
    → @Observable triggers AccountDetailView body re-eval
    → cachedAvatar(for:) reads disk on next render

AccountDetailView Edit-on-clave.casa tap
  → construct bunker URI for current account (existing helper)
  → URL-encode
  → open https://clave.casa/edit#bunker=<encoded>
  → UIApplication.shared.open(url:)
  → Safari → clave.casa → fragment parsed → branch on localStorage match → /edit
```

### State management

- `@State private var petnameInput: String` — unchanged.
- `@State private var showDeleteAlert: Bool` — unchanged.
- `@State private var showRotateBunkerAlert: Bool` — unchanged.
- `@State private var showExportSheet: Bool` — unchanged.
- `@State private var isAboutExpanded: Bool = false` — NEW, governs About block lineLimit.
- `private var account: Account?` computed from `appState.accounts.first { ... }` — unchanged. Load-bearing for Bug-H refresh chain.

## Visual specification

### Banner

```
.padding(.horizontal, 18)
.padding(.vertical, 22)

LinearGradient([theme.start, theme.end], topLeading → bottomTrailing)

HStack(spacing: 14):
  - Avatar 56×56 (treatment A or C per design-doc §4)
    - Treatment A: ZStack { Color(.systemBackground); Image(uiImage:).scaledToFill() }
    - Treatment C: ZStack { Color.white.opacity(0.22); Text(initial).font(.system(size: 22, weight: .heavy)).foregroundStyle(.white) }
    - .clipShape(Circle()).overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 2))
  - VStack(alignment: .leading, spacing: 4):
    - Text(displayLabel).font(.title3).fontWeight(.bold).foregroundStyle(.white)
    - Text(truncatedNpub).font(.system(.caption, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
  - Spacer()
  - Button copy-icon: 30×30 RoundedRectangle(cornerRadius: 7) Color.white.opacity(0.18), 14pt semibold doc-on-doc, .light haptic on tap
```

### Ambient gradient (body)

Per design-doc §6, applied to the Form (NOT the NavigationStack):

```swift
.background(
    LinearGradient(
        stops: [
            .init(color: theme.start.opacity(0.42), location: 0.0),
            .init(color: theme.end.opacity(0.22),   location: 0.30),
            .init(color: theme.end.opacity(0.10),   location: 0.60),
            .init(color: theme.start.opacity(0.04), location: 1.0),
        ],
        startPoint: .top,
        endPoint:   .bottom
    )
    .ignoresSafeArea()
)
.scrollContentBackground(.hidden)
.animation(.easeInOut(duration: 0.3), value: appState.currentAccount?.pubkeyHex)
```

Defensive fallback: if `account == nil` mid-render, use `AccountTheme.palette[0]` (per design-doc §6 fallback rule).

### Section headers

```swift
Section {
    // rows
} header: {
    Text("Petname")
        .font(.headline)
        .foregroundStyle(.white)
        .textCase(nil)
}
.listRowBackground(Color.clear)
```

Same pattern for "Profile", "Security". Delete section uses no header (footer carries the copy).

### Row treatments

**kv-row (Display name / NIP-05 / Lightning):**

```swift
LabeledContent {
    Text(value)
        .foregroundStyle(.white)
        .lineLimit(1)
        .truncationMode(.tail)
} label: {
    Text(label)
        .foregroundStyle(.white.opacity(0.65))
}
.listRowBackground(Color.clear)
```

**about-block (About):**

```swift
VStack(alignment: .leading, spacing: 4) {
    Text("About")
        .foregroundStyle(.white.opacity(0.65))
        .font(.subheadline)
    Text(profile.about ?? "")
        .foregroundStyle(.white)
        .font(.body)
        .lineLimit(isAboutExpanded ? nil : 2)
    if textOverflowsTwoLines {  // see "Overflow detection" below
        Text(isAboutExpanded ? "Show less" : "Show more")
            .foregroundStyle(theme.accent)
            .font(.caption)
            .fontWeight(.medium)
    }
}
.contentShape(Rectangle())
.onTapGesture {
    withAnimation { isAboutExpanded.toggle() }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
}
.listRowBackground(Color.clear)
```

**stat-row (Paired clients):**

```swift
Text("\(connectionCount) paired clients")
    .foregroundStyle(.white.opacity(0.6))
    .font(.caption)
    .frame(maxWidth: .infinity, alignment: .leading)
    .listRowBackground(Color.clear)
```

**action-row (Refresh, Rotate, Export, Edit on clave.casa, Delete):**

```swift
Button { ... } label: {
    HStack {
        Label(title, systemImage: icon)
            .foregroundStyle(theme.accent)  // or .red for destructive
        Spacer()
        if isOutbound {
            Image(systemName: "arrow.up.right.square")
                .foregroundStyle(theme.accent.opacity(0.7))
                .font(.caption)
        }
    }
}
.listRowBackground(Color.clear)
```

### Pair-New-Connection row (HomeView)

Replace existing `pairNewConnectionRow` in `HomeView.swift:321-357` with:

```swift
private var pairNewConnectionRow: some View {
    let theme = AccountTheme.forAccount(pubkeyHex: appState.currentAccount?.pubkeyHex ?? "")
    return Button { handlePairNewConnectionTap() } label: {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(theme.accent.opacity(0.18))
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
            .frame(width: 22, height: 22)
            Text("Pair New Connection")
                .foregroundStyle(theme.accent)
                .font(.body)
                .fontWeight(.medium)
            Spacer()
        }
    }
    .buttonStyle(.plain)
    .listRowBackground(Color.clear)
}
```

No chevron, no subtitle, no icon-circle background. Just a plus glyph + label.

## Behavioral specification

### Pull-to-refresh

```swift
Form { ... }
    .refreshable {
        guard let pubkeyHex = account?.pubkeyHex else { return }
        await appState.refreshProfile(for: pubkeyHex)
    }
```

`refreshProfile(for:)` is already implemented at `AppState.swift:993`. Bypasses the 1-hour throttle for user-initiated refresh. Returns void; the Observable mutation triggers re-render.

### About expand/collapse

State: `@State private var isAboutExpanded: Bool = false`.

Toggle on tap-anywhere-on-block. Light haptic on toggle.

**Overflow detection** (so the "Show more" toggle only renders when relevant):

Use a hidden `Text` measurement via `GeometryReader` + `PreferenceKey`, OR simply check `(profile.about ?? "").count > THRESHOLD` as a cheap heuristic (e.g. `> 80` characters ≈ usually 2+ lines on iPhone). Cheap heuristic acceptable for v0.2.0; can swap to true measurement later if false positives/negatives become a real problem. Spec uses the heuristic.

### Edit on clave.casa

```swift
Button {
    guard let account = account,
          let bunkerURI = SharedStorage.bunkerURIString(for: account.pubkeyHex),
          let encoded = bunkerURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "\(SharedConstants.claveCasaEditBaseURL)#bunker=\(encoded)") else {
        return
    }
    UIApplication.shared.open(url)
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
} label: {
    HStack {
        Label("Edit on clave.casa", systemImage: "person.text.rectangle")
            .foregroundStyle(theme.accent)
        Spacer()
        Image(systemName: "arrow.up.right.square")
            .foregroundStyle(theme.accent.opacity(0.7))
            .font(.caption)
    }
}
.listRowBackground(Color.clear)
```

`SharedStorage.bunkerURIString(for:)` may need to be added if it doesn't exist — the construction logic already lives in `ConnectShowQRView` for QR display; lift to a reusable helper.

### Refresh chain (Bug-H pattern preserved)

- `private var account: Account?` re-derives from `appState.accounts` on every body eval.
- `.onChange(of: account == nil) { _, isNil in if isNil { dismiss() } }` — auto-dismiss when account is deleted while viewing.
- `cachedAvatar(for:)` reads disk synchronously each render (existing pattern).
- All AppState mutations go through MainActor (existing); SwiftUI re-render picks up via @Observable.

## Data model changes

### `CachedProfile` extension

```swift
struct CachedProfile: Codable, Equatable {
    var displayName: String?
    var pictureURL: String?
    var about: String?      // NEW
    var nip05: String?      // NEW
    var lud16: String?      // NEW
    var fetchedAt: Double

    init(displayName: String? = nil,
         pictureURL: String? = nil,
         about: String? = nil,
         nip05: String? = nil,
         lud16: String? = nil,
         fetchedAt: Double) {
        self.displayName = displayName
        self.pictureURL = pictureURL
        self.about = about
        self.nip05 = nip05
        self.lud16 = lud16
        self.fetchedAt = fetchedAt
    }
}
```

Codable handles missing keys via Swift's default decoding behavior for optionals. Existing on-disk `CachedProfile` blobs decode cleanly (the three new fields decode as `nil`). No migration step required — same pattern PR #19 used to extend `ActivityEntry` with three optional fields.

### `AppState.fetchProfile(for:)` extension

The kind:0 JSON parse currently extracts `display_name` (or `name` fallback) and `picture`. Extend to also extract `about`, `nip05`, `lud16`. All three are optional strings in the kind:0 spec. No conditional logic needed beyond `as? String`.

## Pair-New-Connection row redesign

Single-file change in `HomeView.swift` per the visual spec above. Behavioral contract preserved:

- Tap calls `handlePairNewConnectionTap()` which (a) checks the 5-connections-per-account cap via `Account.maxClientsPerAccount`, (b) shows `showConnectionCapAlert` if at cap, (c) otherwise opens `ConnectSheet`.

Cap pre-check pattern unchanged. Defense-in-depth at `ApprovalSheet.buildAndApprove` + `LightSigner` bunker first-connect remains.

## clave.casa coordination

Two items already added to `~/clave-casa/BACKLOG.md` (and the matching memory file `clave-casa.md`):

1. **`/edit#bunker=<encoded>` route** — parse fragment, extract signer pubkey, branch on `connections.ts` localStorage match. Existing pair → ignore secret + nav. New → handshake-pair + nav. `history.replaceState` to scrub fragment after parse.
2. **AASA file** at `/.well-known/apple-app-site-association` scoped tightly to `/connect/?uri=*` only. Critical: must NOT claim `/edit` or apex `/`.

Bundle ID coordination required before clave.casa publishes the AASA — confirm `<TEAMID>.dev.nostr.clave` exact format with iOS Xcode Signing & Capabilities.

iOS-side AASA wiring is Phase B in the rollout plan, separate from this spec.

## Testing approach

### Unit tests

- `ClaveTests/CachedProfileTests.swift` — 5 tests:
  1. Round-trip with all new fields populated.
  2. Round-trip with all new fields nil.
  3. Decode legacy on-disk blob (no `about`/`nip05`/`lud16` keys) → fields decode as nil.
  4. Encode new struct → on-disk JSON contains the new keys.
  5. `Equatable` recognizes differences in the new fields.

### Integration / manual verification

- Build in Xcode (⌘B): no compile errors, no new warnings.
- Run full test suite: all Stage C tests + 178 pre-sprint baseline still passing.
- Simulator: navigate to AccountDetailView via all three entry points (Home active-pill, Home slim-banner, Settings → Accounts row). Each lands on the same view, identity-styled.
- Behavioral exercises:
  - Petname: rename + Save → list updates.
  - Profile: pull-to-refresh → kind:0 fetched, profile fields populate (verify with a test account that has `about`, `nip05`, `lud16` set).
  - About: long bio renders with 2-line cap, "Show more" pill renders, tap expands, "Show less" collapses. Short bio renders no toggle.
  - Security: rotate bunker secret (named alert fires), export private key visible only when current account.
  - Delete: alert shows account name + connection count, confirm deletes + auto-dismisses.
  - Switch active account while AccountDetailView is open for a different account: re-derives `account`, banner + ambient gradient + Profile fields all update.
- Pair-New-Connection row: visually distinct from a `ConnectedClient` row at a glance. Tap opens ConnectSheet. Cap pre-check fires at 5 connections.
- Edit-on-clave.casa: tap opens Safari → clave.casa. Manual end-to-end requires clave.casa apex deployment + `/edit` route shipped (parallel session work). Until then, tap opens the static landing or 404 — fine for v0.2.0 since clave.casa apex deployment is parallel-tracked.

## Open questions / future work

- **Live `nip05` verification.** v0.2.0 displays the string as-is. Future: fetch `https://<domain>/.well-known/nostr.json?name=<local>`, confirm pubkey match, render a checkmark badge on success. Adds a network call per profile load; needs caching to avoid spamming.
- **Live `lud16` verification.** Similar — fetch the LNURL well-known endpoint and confirm. Lower priority than nip05.
- **`ExportKeySheet` pubkey-param refactor.** Currently gated to current account; future refactor parameterizes so any account can export. Out of scope for this spec; tracked in `stage-c-sprint.md` polish backlog.
- **About overflow detection.** v0.2.0 uses `count > 80` heuristic; if false positives/negatives become a real problem on device, swap to true text-measurement via `GeometryReader` + `PreferenceKey`. Defer until evidence warrants.
- **`SharedStorage.bunkerURIString(for:)` helper.** Construction logic exists in `ConnectShowQRView`; the Edit-on-clave.casa link needs the same logic. Lift to a reusable helper as part of this sprint to avoid duplication.
- **Profile fetch when AccountDetailView is opened cold.** Today, profile fetch is throttled per-account (1 hour). User opening AccountDetailView for an account with no cached profile sees empty Profile section until they pull-to-refresh. Could trigger a throttle-bypassing fetch in `.onAppear` if `account.profile == nil`. Low priority; pull-to-refresh covers it functionally. Add to follow-up if user reports the gap.
- **clave.casa link visible before clave.casa apex is deployed.** Always-visible was the intentional decision (avoid gating logic). If the row is tapped before clave.casa deploys, Safari opens to a 404 or Cloudflare error page. Acceptable for v0.2.0 since clave.casa apex deployment is the top backlog item on the parallel session and should land before or with v0.2.0-build45.
