# Stage C Home Redesign — Instagram-stories Style

**Date:** 2026-05-02
**Status:** Brainstorming complete; awaiting plan
**Sprint:** Stage C UX iteration on `feat/multi-account`
**Builds on:** [Stage C multi-account UX](2026-05-01-stage-c-multi-account-ux-design.md) (build 38) — same surfaces, polished after real-device feedback.

## Context

Build 38 ships the v4 strip mockup faithfully — 38pt pills inside a frosted-white card, with a separate `SlimIdentityBar` row beneath. On real device, the user reported it "is nothing like the v4 mockups" and shared an Instagram stories-row screenshot as the new target.

This redesign polishes the existing Home top section — strip, slim bar, ambient gradient, toolbar — into an Instagram-stories-inspired identity zone. No new surfaces, no protocol changes. The polish folds (Account.displayLabel consolidation, AccountTheme guards, AccountNavTarget extraction, auto-fetch profiles, Pair New Connection visibility, AccountDetailView reorder) shipped in commit `eb42583` ahead of this spec; this doc covers only the Home-redesign portion.

## Goals

- Strip pills feel substantial, not crowded — bigger avatars, more breathing room, no enclosing card.
- Active account is unmistakable at a glance — bold theme-gradient ring + bold label.
- Inactive accounts are framed but quiet — subtle hairline ring, regular weight label.
- Slim identity bar is a deliberate, themed affordance with a visible link to AccountDetailView (currently it has copy but no nav).
- Ambient gradient continues to give per-account identity to the screen, but doesn't overwhelm.
- Toolbar is minimal — just "Clave", iOS-native inline.

## Non-goals

- Stats row redesign (the three "Signed Today / Clients / Pending" cards) — out of scope.
- Per-account theming on inactive pills — all inactive pills get the same neutral hairline; only active is themed.
- New navigation paths or new Home sections.
- Tab bar accent theming, robohash, pending-approval per-pill badge — remain on the polish backlog.

## Locked design decisions

Captured during brainstorming session at `~/clave/Clave/.superpowers/brainstorm/57998-1777732941/`.

### Strip (`AccountStripView`)

| Property | Locked value | Was (build 38) |
|---|---|---|
| Avatar diameter (`pillSize`) | **60pt** | 38pt |
| Active ring padding (`ringPadding`) | **5pt** (gradient ring is 5pt thick on each side) | 3pt |
| Pill spacing (HStack `spacing`) | **18pt** | 14pt |
| Outer padding | **`.horizontal: 14, .vertical: 12`** | `.horizontal: 8, .vertical: 10` |
| Frosted-card wrapper | **REMOVED** | Present (`.ultraThinMaterial` + accent stroke) |
| Inactive ring | **1pt hairline at `Color.secondary.opacity(0.25)`** (auto light/dark adaptive) | None |
| Avatar placeholder font | **`pillSize * 0.37` ≈ 22pt at 60pt avatar** | 14pt |
| Add-pill `+` glyph | **22pt, .semibold** | 17pt |
| Auto-hide when `accounts.count == 1` | unchanged | unchanged |
| Active-pill label weight | `.heavy` in `theme.accent` (unchanged) | unchanged |
| Inactive-pill label weight | `.semibold` at `Color.primary.opacity(0.8)` (unchanged) | unchanged |

### Ambient gradient (`HomeView.homeBackgroundGradient`)

| Stop | Locked opacity | Was (build 38) |
|---|---|---|
| 0.0 (top) | **0.28** | 0.35 |
| 0.35 | **0.18** | 0.22 |
| 0.70 | **0.12** | 0.14 |
| 1.0 (bottom) | **0.06** | 0.10 |

Same per-account `theme.start → theme.end` colors; same `LinearGradient(.top → .bottom)`; same `.ignoresSafeArea()` and `.easeInOut(duration: 0.3)` switch animation.

### Slim identity bar (`SlimIdentityBar`) — polished mini-banner

A solid theme-gradient bar with a mini avatar, petname, npub, inline copy button, and chevron. The whole row is tappable and pushes `AccountDetailView` for the current account. Visual continuity with `AccountDetailView`'s full-bleed banner header.

| Property | Locked value | Was (build 38) |
|---|---|---|
| Background | **`LinearGradient(theme.start → theme.end)` solid** (no opacity) | 22%/16% gradient wash |
| Border | **None** (solid background does the framing) | 1pt accent stroke |
| Corner radius | 12pt (was 11) — slight bump to feel more deliberate | 11 |
| Mini avatar | **NEW: 28pt circle, white-on-gradient initial, 1.5pt white-22% border** | n/a |
| Petname | `.system(size: 14, weight: .heavy)`, white | `.system(size: 12, weight: .heavy)` primary tint |
| Npub | `.system(size: 9.5, design: .monospaced)`, white-85% | `.system(size: 10, design: .monospaced)` secondary tint |
| Copy button | 26pt rounded square, white-22% bg, white icon | 22pt with white-92% bg over text |
| Chevron | **NEW: trailing `chevron.right` 12pt, white-85%** | n/a |
| Whole-row tap | **NEW: pushes `AccountDetailView` for current account** via `appState.pendingDetailPubkey` (same path active-pill tap uses) | Copy-only; no nav |
| Outer padding | `.horizontal: 14, .vertical: 4-bottom-12` | `.horizontal: 12, .top: 8` |
| Drop shadow | **NEW: 0/1/8 at theme.start.opacity(0.25)** for slight lift | None |

The mini-banner replaces — not augments — the build-38 SlimIdentityBar wash treatment.

### Toolbar (`HomeView`)

| Property | Locked value | Was (build 38) |
|---|---|---|
| Mode | **`.navigationBarTitleDisplayMode(.inline)`** | Default (large) |
| Title | `"Clave"` via existing `.navigationTitle("Clave")` (kept) — no custom `ToolbarItem(.principal)` | Same string, large display mode |
| Other items | None (matches build-38 post-`fb6e7e7` state) | None |

### What's gone / what's renamed

- **`AccountAvatarPlaceholder`** font size: hard-coded 14pt → derive from `pillSize` (still placed in `AccountStripView.swift`).
- **Frosted-card wrapper** on the strip — deleted.
- **`SlimIdentityBar` body** — fully rewritten (kept the file; same struct name; same call site in `HomeView`). All 4 lines of its `body` get replaced.
- **`HomeView.navigationTitle("Clave")` display mode** — large → inline.
- **Toolbar `+`** — already removed in `fb6e7e7` (Stage C device-test fix). No change needed.

## Architecture

No new types, no new files. The redesign edits four existing files:

```
Clave/Views/Home/AccountStripView.swift   (strip refactor — sizes, no card, ring style)
Clave/Views/Home/SlimIdentityBar.swift    (rewrite body to mini-banner)
Clave/Views/Home/HomeView.swift           (toolbar inline, gradient retune, ensure SlimIdentityBar tap path works)
```

The pre-existing affordances stay verbatim:
- `AccountPillView.didLongPress` flag (suppresses tap-after-long-press).
- `AccountStripView.cachedAvatar(for:)` reading `cached-profile-<pubkeyHex>.dat` (Bug E fix).
- `onSwitch` / `onPushDetail` split — non-active tap = switch; active tap = push detail.
- Bug H refresh chain — `onChange(of: appState.currentAccount?.pubkeyHex)` in `HomeView`.
- `AccountTheme.forAccount(pubkeyHex:)` — drives both strip rings and slim-banner background.

The slim-banner tap routes through `appState.pendingDetailPubkey` (same hook the active-pill long-press uses), so `HomeView`'s NavigationStack `onChange(of: pendingDetailPubkey)` modifier already handles the push.

## Data flow (slim-bar tap)

```
User taps SlimIdentityBar
  → SlimIdentityBar.body Button action
    → appState.pendingDetailPubkey = appState.currentAccount?.pubkeyHex
       UIImpactFeedbackGenerator(.medium).impactOccurred()
  → HomeView.onChange(of: appState.pendingDetailPubkey) fires
    → navigationPath.append(AccountNavTarget.detail(pubkey: pubkey))
    → appState.pendingDetailPubkey = nil
  → NavigationStack pushes AccountDetailView(pubkeyHex:)
```

Identical to the existing active-pill-tap path. Zero new state machinery.

## Error handling

- `appState.currentAccount == nil`: `SlimIdentityBar` already returns `EmptyView` (it's `if let current = appState.currentAccount` gated). Mini-banner inherits this guard; no signing-key-imported state means no slim bar.
- `AccountTheme.forAccount(pubkeyHex:)` falls back to `palette[0]` for empty/invalid hex (now also non-64-char hex per the polish-fold guard tightening). Mini-banner background never crashes.
- Tap on slim-bar with empty pendingDetailPubkey: HomeView's `onChange` only fires on non-nil values; no-op on empty.

## Testing

No unit tests for the visual changes — view-only modifications. Existing `AccountThemeTests` (6 tests) still pass; not affected by this redesign.

Manual verification on real device after build:
- Strip pills 60pt, no frosted card, gradient visible behind.
- Active pill 5pt gradient ring; inactive pills 1pt subtle hairline.
- Tap non-active pill → switches account; Connected Clients + Activity refresh (Bug H).
- Tap active pill → pushes `AccountDetailView`.
- Long-press any pill → pushes detail without switching.
- Tap slim-banner anywhere → pushes `AccountDetailView` for current account.
- Long-press copy button → copies npub (separate gesture from row tap; existing copy behavior unchanged).
- Toolbar shows "Clave" inline at top.
- Single-account user: strip auto-hides; slim-banner remains visible.
- PFPs render on strip for all accounts (auto-fetch from prior commit).
- Account deletion still dismisses detail view.

## Implementation order

1. `AccountStripView.swift` — pill sizing, ring style, no frosted card. Hardest part to get right; verify visually on device first.
2. `HomeView.swift` — gradient retune (single LinearGradient `stops:` array edit) + `.navigationBarTitleDisplayMode(.inline)`.
3. `SlimIdentityBar.swift` — full body rewrite to mini-banner. Add tap → `pendingDetailPubkey`.
4. Verify on device against the manual checklist.
5. Commit + push.

## Out of scope (deferred)

- Polish backlog items: AccountTheme palette device verification, AppState file size split, ExportKeySheet pubkey-param refactor, robohash, tab bar accent theming, pending-approval per-pill badge, NSE notification body account label, generate-account backup checkbox, ConnectedClient row creation in bunker connect path
- Stats row redesign
- pbxproj 39→40 bump + URL revert in `Shared/SharedConstants.swift:14`
- Production rollout sequence (PR #22 → Dell deploy → URL revert → build 40 → PR #23)
- Build 38 device verification of `fb6e7e7` + `af37a66` fixes (separate next-session task per HANDOFF)
- ClaveTests deployment-target lower (standalone PR, anytime)

## References

- Brainstorm session: `~/clave/Clave/.superpowers/brainstorm/57998-1777732941/`
  - `strip-variants-v1.html` — 56/60/68pt avatar comparison (locked B: 60pt)
  - `gradient-intensity.html` — Strong/Medium/Subtle (locked Strong: 28/18/12/6)
  - `slim-bar-variants.html` — current/mini-banner/hairline (locked B: mini-banner)
  - `toolbar-variants.html` — plain/bold/rounded (locked A: plain inline)
- Previous spec: `docs/superpowers/specs/2026-05-01-stage-c-multi-account-ux-design.md` (Stage C build 38)
- Sprint state: `~/.claude/projects/-Users-danielwyler-hq-clave/memory/stage-c-sprint.md`
- Approved v4 mockup (build 38 reference): `~/clave/Clave/.superpowers/brainstorm/65381-1777677108/content/picker-c2-themed-v4.html`
