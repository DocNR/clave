# Stage C — Stripped-Down Multi-Account UX Design Spec

_Status: approved 2026-05-01 via `superpowers:brainstorming` session. Ready for `superpowers:writing-plans` transition. Visual mockups archived in `.superpowers/brainstorm/65381-1777677108/content/` (gitignored)._

## Problem

Phase 1 / Stage B (builds 34–37) shipped multi-account end-to-end at the data + signing layer. Eight bugs (A–H) were caught and fixed during real-device smoke testing. The interim Home identity-bar Menu (`aa194a9`) unblocked tester switching but iOS-native menu styling can't show stacked avatar + name + npub rows or convey per-account identity at rest. Multi-account currently feels like a hidden feature: users must tap to discover their other accounts, no visual signal communicates which account is signing, and destructive actions don't name the active account in their copy.

The core risk: with multiple accounts present, users may accidentally pair connections, sign requests, or delete state under the wrong account because the chrome doesn't reinforce active identity strongly enough.

## Goals

1. **Always-visible overview of all accounts** — open Clave, scan, recognize state without interaction. Fits the "background utility, set-and-forget" mental model the user holds for Clave.
2. **One-tap account switching** — no modal layer for the most common interaction.
3. **Unmistakable active identity** — gradient theming permeates the Home background so it's impossible to misread which account is signing.
4. **Prevent accidental cross-account actions** — destructive copy explicitly names the affected account.
5. **Keep the chrome neutral where real images will live** — user PFPs (kind:0 picture URLs) and client favicons should dominate their respective surfaces; theming flows through chrome backgrounds, not avatar/icon spaces.

## Non-goals (explicitly deferred)

- OnboardingView `.addAccount` mode parameterization — replaced by a simpler `AddAccountSheet` modal for now. Full onboarding refactor is a future iteration.
- PendingApprovalsView per-account grouping — current single-list view is acceptable.
- iOS notification body with account label — NSE crypto-stack changes carry risk; defer to dedicated sprint.
- Confirmation alert for generate-account backup acknowledgement — UX polish, ship in follow-up.
- ConnectedClient row creation in bunker connect path — pre-existing gap, separate fix unrelated to this UX sprint.
- Pending-approval badge per strip pill — future enhancement.
- User-customizable account colors — hash-derived deterministic mapping only for now.

## Design

### Picker pattern (C2): top avatar strip + slim text identity bar

**Top avatar strip** (`AccountStripView.swift`):

- Horizontal `ScrollView` over `appState.accounts`.
- Each account renders as a 40-pt circular avatar pill with a small label (petname / display name / truncated pubkey) underneath.
- Active account: 3-pt gradient ring around its avatar, label gets `font-weight: 800` + accent color.
- Trailing `+` pill (dashed circle, `+` glyph) at the rightmost position.
- Strip auto-hides entirely when `accounts.count == 1` so single-account users see the same Home as build 31.
- Strip card itself is frosted-white (`rgba(255,255,255,0.55)` over the gradient background) so the chrome doesn't compete with the active pill ring.

**Interactions:**

| Gesture | Result |
|---|---|
| Tap non-active pill | `appState.switchToAccount(pubkey:)` — Bug H wiring already triggers HomeView/ActivityView refresh chain |
| Tap active pill | `NavigationLink` push → `AccountDetailView` for current account |
| Long-press any pill | `NavigationLink` push → `AccountDetailView` for that account *without* switching active |
| Tap `+` pill | Present `AddAccountSheet` modally |

**Slim identity bar** (`SlimIdentityBar.swift`), below the strip:

- Single line: `@<petname or displayName> • <truncated npub> [📋 copy]`
- No avatar (the strip already shows it — avoid duplication)
- Background: 22% opacity gradient wash matching active account, 1pt accent border
- Tap copy icon → existing pasteboard logic + `UIImpactFeedbackGenerator(.light)` haptic

### Per-account gradient theming

**Color generation** (`AccountTheme.swift`):

- Deterministic from pubkey hex: SHA-256 → take 2 bytes → map to one of 12 distinct gradient pairs
- Palette curated to avoid clashy hues, yellows-on-white, and low-contrast pairs
- Each gradient is a 2-stop linear gradient at 135°: `start → end`
- Sample palette entries:
  - Purple/violet: `#7b8cff → #a14bff`
  - Teal/aqua: `#00c8ff → #2dffb5`
  - Coral/amber: `#ff8c4b → #ffc14b`
  - Magenta/pink: `#ff4b8c → #ff77a8`
  - Sky/cyan: `#4ba4ff → #4be8ff`
  - Lime/grass: `#4bff8c → #c1ff4b`
  - (...12 total)

**Application surfaces (where the theme shows up):**

| Surface | Theming applied |
|---|---|
| HomeView background | Full-bleed gradient: 35% opacity at top → 22% at 35% → 14% at 70% → 10% at bottom. Never transparent. |
| Strip card | Neutral frosted white. Active pill ring carries the only visible gradient inside the strip. |
| Slim identity bar | 22% opacity wash background + accent border |
| Active strip pill | 3-pt gradient ring; label color matches darkest hue of gradient |
| `AccountDetailView` header | Full-bleed gradient banner (large avatar + name + npub on the gradient) |
| `ApprovalSheet` "Signing as" header | Tinted mini-bar (12% wash + accent border) under the request signer's gradient |
| Active tab in tab bar | Accent text color + bold weight (no pill background) |

**Application surfaces (where chrome stays neutral):**

| Surface | Why neutral |
|---|---|
| Pill avatar interiors | Will be replaced with kind:0 picture URLs (real PFPs) |
| Connection-row leading icons | Will be replaced with client favicons (Nostur logo, etc.) |
| Activity-row glyphs | Utility iconography (✓/✎/♥), not theming surface |
| Section labels | Neutral gray, weight-600 |
| Connection rows | White frosted-glass cards (78% opacity over gradient bg) with subtle shadow, no accent border |
| Tab bar background | Neutral white frosted glass |
| Copy-button color | Neutral gray |

**Rationale:** Background does ~80% of the theming work. Once real images replace placeholders, the avatar/favicon spots stop carrying theme — the gradient still dominates the "ambient identity" perception.

### Explicit account names in destructive copy

| Surface | Old copy | New copy |
|---|---|---|
| ApprovalSheet body | "Approve sign request" | "Sign as **@Alice**: kind:1 note" |
| Unpair alert | "Unpair Client?" | "Unpair Nostur from **@Alice**?" |
| Delete account alert | "Delete account?" | "Delete **@Alice**? Permanently removes the key and unpairs N connections." |
| Rotate bunker confirmation | "Rotate secret?" | "Rotate bunker secret for **@Alice**? Existing pairings continue working." |
| AddAccountSheet generate result | (none) | Toast: "Generated **@Test 18:42**" |
| AddAccountSheet paste result | (none) | Toast: "Added **@Alice**" |

Implementation: ~5 lines per surface, mostly string changes. Account name lookup uses `petname ?? displayName ?? truncatedPubkey` chain.

### AddAccountSheet

`AddAccountSheet.swift` — modal sheet with `.medium` detent.

Layout:
1. Title: "Add Account"
2. Mode picker: segmented control "Generate new" / "Paste nsec"
3. Form (mode-dependent):
   - **Generate** mode: optional petname text field, "Generate" button → `appState.generateAccount(petname:)` → dismisses → strip auto-switches active to new account → toast confirmation
   - **Paste** mode: nsec text field (secure entry), optional petname, "Add" button → `appState.addAccount(nsec:petname:)` → dismisses + auto-switches → toast confirmation. Inline error states for invalid nsec / duplicate (existing `addAccount` idempotency surfaces "already added" → silent switch + toast).

Reuses existing `AppState.addAccount` / `generateAccount` methods. No new business logic.

### AccountDetailView

`AccountDetailView.swift` — per-account detail screen reachable from `AccountStripView` (tap active pill, long-press any pill) and from `SettingsView` Accounts section.

Layout (top to bottom):

1. **Gradient banner header** — full-bleed band ~120pt tall using account's gradient. Contains:
   - 56-pt avatar (real PFP if cached, else placeholder)
   - Display name (or petname) — 18pt bold white
   - Truncated npub — 11pt monospaced, 85% white opacity
   - Copy-npub button (top-right corner of banner)

2. **Profile section** (read-only) — kind:0 fields when present:
   - Display name (separate from petname)
   - NIP-05
   - Lightning address (lud16)
   - Website / about

3. **Petname section** — text field bound to local state, "Save" button calls `appState.renamePetname(for: pubkey, to: newPetname)`. Sanitization (trim + strip newlines + cap 64) already in audit-A3 implementation.

4. **Actions section** (disclosure rows):
   - Refresh profile → `appState.refreshProfile(for: pubkey)` (new helper, see Data Flow below)
   - Rotate bunker secret → confirmation alert with named copy → `appState.rotateBunkerSecret(for: pubkey)`
   - Export private key → existing `ExportKeySheet` (already supports `loadNsec(for:)`)
   - Delete account (destructive, red) → confirmation alert with named-account copy → `appState.deleteAccount(pubkey:)` → pop view

### SettingsView Accounts section

Replaces the existing "Signer Key" section.

```
┌─────────────────────────────────┐
│ ACCOUNTS                        │
├─────────────────────────────────┤
│ [avatar] @Alice              ›  │
│         npub1d6a4f1q…d681449    │
├─────────────────────────────────┤
│ [avatar] @Bob               ›   │
│         npub1f025db2…707c5d5b   │
├─────────────────────────────────┤
│ ⊕ Add Account                   │
└─────────────────────────────────┘
```

- Each account row is a `NavigationLink` → `AccountDetailView`
- Row content: 32-pt avatar + display name (bold) + truncated npub (smaller, gray)
- Trailing "Add Account" row presents `AddAccountSheet` (same sheet as `+` strip pill)

### ApprovalSheet "Signing as" header

`SigningAsHeader.swift` prepended to the existing `ApprovalSheet` body.

Layout:
- 24-pt mini avatar (real PFP) on the left
- `Text("Signing as ").foregroundStyle(.secondary) + Text("@\(name)").bold()` to the right
- Background: 12% gradient wash + 1pt accent border (matching the request signer's account color)
- Falls back to truncated pubkey hex when petname/displayName both nil

Lookup: `request.signerPubkeyHex` → find matching `Account` in `appState.accounts` → render with that account's theme.

## Architecture

### View tree

```
HomeView
├── (existing) Tab nav (Home / Activity / Settings)
├── NEW Background gradient overlay (account-themed)
├── NEW AccountStripView
│   └── ForEach(accounts) → AccountPill + trailing AddPill
├── NEW SlimIdentityBar
│   └── @petname • npub • CopyButton
├── (existing) Connected Clients section
├── (existing) Recent Activity section
└── (existing) Tab bar

SettingsView
├── (existing) Other settings sections
├── NEW AccountsSection
│   └── ForEach(accounts) → NavigationLink(AccountDetailView)
│   └── trailing "Add Account" → presents AddAccountSheet
└── (existing) other settings

AccountDetailView (NEW, navigation-pushed)
├── GradientBanner
├── ProfileSection
├── PetnameSection
└── ActionsSection (rotate / export / delete / refresh)

ApprovalSheet
├── NEW SigningAsHeader (prepended)
└── (existing) approval body

AddAccountSheet (NEW, modally presented)
├── Mode picker (Generate / Paste)
└── Form
```

### Data flow

`AppState.fetchProfileIfNeeded()` currently operates only on the current account. AccountDetailView's "Refresh profile" needs to fetch for an account that may not be current.

**Refactor:** extract a private helper `fetchProfile(for: pubkey: String) async` that performs the relay-fan-out logic without depending on `signerPubkeyHex`. Existing `fetchProfileIfNeeded()` becomes a thin wrapper. New public `appState.refreshProfile(for: pubkey)` exposed for AccountDetailView.

~30 lines of extract-and-rename. No behavior change for existing callers.

### Theming module

`AccountTheme.swift` — pure utility, no UIKit/SwiftUI dependencies.

```swift
struct AccountTheme {
  let start: Color   // gradient start (135° angle)
  let end: Color     // gradient end
  let accent: Color  // text accent (= darkest of start/end at 1.0 opacity)
}

extension AccountTheme {
  static func forAccount(pubkeyHex: String) -> AccountTheme
  static let palette: [AccountTheme]  // 12 curated entries
}
```

Hash function: `SHA256(pubkeyHex.lowercased()).first(2 bytes) → uint16 → % palette.count → palette[index]`. Deterministic, no state, easy to unit-test.

### Existing patterns reused

- `appState.accounts` (Observable) → views auto-rerender on add/delete
- `appState.currentAccount?.pubkeyHex` → drives all theming via `AccountTheme.forAccount(pubkeyHex:)`
- `appState.switchToAccount(pubkey:)` → already wires Bug G (PFP refresh) + Bug H (HomeView + ActivityView refresh)
- `appState.addAccount(nsec:petname:)` / `generateAccount(petname:)` → existing methods, AddAccountSheet just presents UX
- `appState.deleteAccount(pubkey:)` → existing audit-A2 ordering, AccountDetailView triggers + handles pop-view
- `appState.renamePetname(for:to:)` → existing sanitization (audit A3)
- `appState.rotateBunkerSecret(for:)` → existing per-account rotation
- `ExportKeySheet` → existing biometric-gated nsec export, supports per-account via `loadNsec(for:)`

## Error handling

- **AddAccountSheet paste with invalid nsec** → existing `Keys.parse(secretKey:)` throws → caught → inline error label below text field, sheet stays open for retry
- **AddAccountSheet paste duplicate** → existing `addAccount` idempotency: switches to existing account, returns existing → AddAccountSheet treats as success, dismisses + toast "Switched to **@<existing petname>**"
- **AccountDetailView refresh-profile network failure** → existing `fetchProfile` silent-fail pattern. AccountDetailView shows a brief "couldn't refresh" toast.
- **AccountDetailView delete-account interruption** → audit-A2 ordering ensures partial-completion is recoverable: re-deleting completes the cleanup.
- **AccountDetailView rotate-bunker-secret on non-current** → uses explicit signer parameter; works regardless of which account is current.
- **Strip horizontal overflow** → `ScrollView(.horizontal, showsIndicators: false)` handles 6+ accounts gracefully.
- **AccountTheme palette fallback** → if hash maps to invalid index, defaults to first palette entry. Defensive only; should never fire.

## Testing

**Unit tests** (XCTest):
- `AccountThemeTests` — verify deterministic mapping (same pubkey → same theme), palette coverage (~12 distinct themes used across N random pubkeys), invalid pubkey hex defaults safely
- Existing `AppStateMultiAccountTests` cover the underlying multi-account behavior; no new test for `refreshProfile(for:)` since it's a near-mechanical extract

**Manual / on-device smoke (build 38)**:
- Strip switching: tap each pill, verify Home + Activity refresh
- Strip auto-hide: delete down to 1 account, verify strip disappears, single-account UX restored
- Add via `+` pill: generate → toast → strip shows new pill + auto-switches
- Add via Settings → Accounts → Add Account: paste nsec → toast → strip + Settings list both updated
- AccountDetailView: rename petname → reflects in strip + Settings + slim bar; delete → pops, account removed everywhere
- Theming: switch through 4 accounts with different gradient hues — verify background shifts, slim bar wash shifts, AccountDetailView banner shifts
- ApprovalSheet header: trigger a protected-kind sign request — verify "Signing as @<account>" header appears with correct theming
- Destructive copy: trigger unpair, delete account, rotate bunker — verify alerts name the affected account explicitly

## Implementation order (commit sequence)

1. **`AccountTheme.swift`** — pure utility, no UI dependencies. Foundation for everything else. Include unit tests.
2. **`AccountStripView` + `SlimIdentityBar` + HomeView swap** — most visible. Validates pattern. Test: switch via strip, verify Bug G (PFP) + Bug H (refresh) chains still work.
3. **`AddAccountSheet` + `+` pill wiring** — completes strip's add affordance.
4. **`AccountDetailView` skeleton** (gradient banner + petname rename + delete only) — minimum viable detail.
5. **`AccountDetailView` actions** (rotate bunker, export, refresh profile, profile section) — completes detail view.
6. **`SettingsView` AccountsSection + nav to AccountDetailView** — second entry point.
7. **`ApprovalSheet` SigningAsHeader + destructive copy updates across alerts** — clarity for cross-account protection.
8. **pbxproj bump 37→38, archive build 38** — internal-TF smoke. URL flip retained.

Each commit builds + runs in simulator before the next. No commits without a green build. Smoke checklist runs on real device after step 8.

## Out-of-scope follow-ups (next sprint candidates)

- OnboardingView `.addAccount` mode parameterization (replaces AddAccountSheet's minimal flow with a richer onboarding path including mnemonic display, security tips, etc.)
- PendingApprovalsView per-account grouping
- iOS notification body with account label (NSE change)
- Generate-account backup acknowledgement checkbox in AddAccountSheet
- ConnectedClient row creation in bunker connect path (currently only nostrconnect creates this row → ActivityDetailView greys connection link for bunker users)
- Pending-approval badge per strip pill (small dot top-right of avatar when account has unhandled requests)
- User-customizable account colors (color picker in AccountDetailView; replaces hash-derived default)
- Robohash-derived default avatars when no kind:0 picture is set — fallback chain becomes `kind:0 picture URL → cached robohash from pubkey hex → letter-on-gradient`. Adds ~30 lines (URL fetch + local cache file `cached-robohash-<pubkey>.png` alongside the existing profile cache). Network dependency on robohash.org with first-load pubkey leak; cache mitigates after first fetch. Worth it for visual distinctness when no PFPs are set, but not required to ship the picker.

## Branch + ship strategy

- All work stacks on `feat/multi-account` (no new branch)
- Build 38 stays internal-TF; URL flip retained until prod rollout
- **Hard hold on prod rollout: not before 2026-05-02.** User wants build-31 external testers ≥24h notice + key-backup window before any production proxy change lands.
- Pre-rollout checklist (next session, after backup window passes):
  1. Confirm tester comms went out
  2. Merge PR #22 to main, deploy to `/opt/clave-proxy/`, verify health
  3. URL revert + pbxproj 38→39 in single commit on `feat/multi-account`
  4. Archive build 39 against prod proxy, internal smoke
  5. Mark PR #23 ready, squash-merge, tag `v0.1.0-build39`, GH Pre-release
  6. Promote external in ASC

## Open questions to resolve during implementation

- **AccountDetailView refresh-profile** — should it show a spinner during fetch? Decision during commit 5.
- **AccountDetailView profile section empty state** — when an account has no kind:0 published, what does the section show? Probably hide entirely + suggest "Refresh profile" action.
- **Strip horizontal overflow indicator** — 7+ accounts crowd the visible strip. Add a subtle right-edge gradient hint to suggest scrolling? Decision during commit 2.
- **Theming on iPad / large screens** — current spec assumes iPhone. iPad sees same Home but with more horizontal space; gradient should still feel right. Probably no change needed; verify during commit 2.
