# Stage C — Multi-Account UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a strip-based account picker with per-account gradient theming, replacing the interim Menu (`aa194a9`) on Home and adding an AccountDetailView, AddAccountSheet, Settings Accounts section, and ApprovalSheet "Signing as" header.

**Architecture:** New SwiftUI views layered on existing `AppState` Observable infrastructure. One pure utility (`AccountTheme`) with hash-derived deterministic gradient mapping. View tree: `HomeView` (gradient bg) contains `AccountStripView` + `SlimIdentityBar`; `SettingsView` gets `AccountsSection` linking to new `AccountDetailView`; `ApprovalSheet` prepends `SigningAsHeader`. Existing AppState methods (switch/add/delete/rename/rotate) reused as-is. Small refactor: extract `fetchProfile(for: pubkey)` private helper so AccountDetailView can refresh non-current accounts.

**Tech Stack:** SwiftUI (`@Observable` AppState pattern), XCTest, CryptoKit (SHA-256 for color hash), iOS 17+. Branch `feat/multi-account` (no new branch — stacks on top of build 37 commits).

**Spec:** `docs/superpowers/specs/2026-05-01-stage-c-multi-account-ux-design.md`

---

## Conventions

- All commits use the existing repo identity helper: `git -c user.name="DocNR" -c user.email="thehypoxicdrive@gmail.com" commit -m "..."`
- Build verification command (use after every UI task): `xcodebuild -scheme Clave -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -3` — expects `** BUILD SUCCEEDED **`
- Test command (XCTest only — for AccountTheme task): `xcodebuild -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4' test -only-testing:ClaveTests/AccountThemeTests 2>&1 | grep -E "Test Suite|passed|failed"`
- Working directory for all `git` and `xcodebuild` commands: `/Users/danielwyler/clave/Clave/`
- After every commit, push: `git push origin feat/multi-account`

---

## Task 1: AccountTheme palette helper (TDD, fully unit-tested)

**Files:**
- Create: `Clave/Shared/AccountTheme.swift`
- Create: `ClaveTests/AccountThemeTests.swift`

**Why TDD here:** `AccountTheme` is a pure deterministic utility — input pubkey hex, output `(start, end, accent)` Color triplet. No UI dependencies. Easy to test all the invariants (determinism, palette coverage, fallback).

### Step 1.1: Write the failing test file

- [ ] **Step 1.1: Write failing tests** — Create `ClaveTests/AccountThemeTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import Clave

final class AccountThemeTests: XCTestCase {

    // The palette must contain exactly 12 distinct entries (per spec).
    func testPalette_hasTwelveEntries() {
        XCTAssertEqual(AccountTheme.palette.count, 12)
    }

    // Same pubkey → same theme, every time. Critical for visual stability.
    func testForAccount_isDeterministic() {
        let pk = "d6a4f1b71acb4c0b989ed61a695cd438f219463d3983b5b457791e5e6d681449"
        let a = AccountTheme.forAccount(pubkeyHex: pk)
        let b = AccountTheme.forAccount(pubkeyHex: pk)
        XCTAssertEqual(a.paletteIndex, b.paletteIndex)
    }

    // Different pubkeys typically map to different themes (not a hard guarantee
    // — palette is finite, collisions exist — but across N=100 random pubkeys
    // we should see at least 8 of the 12 themes hit. Validates distribution.
    func testForAccount_distributesAcrossPalette() {
        var seen = Set<Int>()
        for _ in 0..<100 {
            let randomHex = (0..<32).map { _ in
                String(format: "%02x", UInt8.random(in: 0...255))
            }.joined()
            seen.insert(AccountTheme.forAccount(pubkeyHex: randomHex).paletteIndex)
        }
        XCTAssertGreaterThanOrEqual(seen.count, 8,
            "100 random pubkeys should hit at least 8 of 12 palette entries; got \(seen.count)")
    }

    // Empty hex string falls back to the first palette entry safely.
    func testForAccount_emptyHexReturnsFirstPaletteEntry() {
        let theme = AccountTheme.forAccount(pubkeyHex: "")
        XCTAssertEqual(theme.paletteIndex, 0)
    }

    // Non-hex / malformed input also falls back safely.
    func testForAccount_invalidInputReturnsFirstPaletteEntry() {
        let theme = AccountTheme.forAccount(pubkeyHex: "not-hex-at-all")
        XCTAssertEqual(theme.paletteIndex, 0)
    }

    // Lowercase + uppercase + mixed case of the same pubkey produce the same theme.
    // (Defense — pubkey hex is conventionally lowercase but we shouldn't trip on case.)
    func testForAccount_isCaseInsensitive() {
        let lower = "d6a4f1b71acb4c0b989ed61a695cd438f219463d3983b5b457791e5e6d681449"
        let upper = lower.uppercased()
        XCTAssertEqual(
            AccountTheme.forAccount(pubkeyHex: lower).paletteIndex,
            AccountTheme.forAccount(pubkeyHex: upper).paletteIndex
        )
    }
}
```

- [ ] **Step 1.2: Run test, verify it fails to compile**

Run: `xcodebuild -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4' test -only-testing:ClaveTests/AccountThemeTests 2>&1 | tail -5`

Expected: compile error mentioning `AccountTheme` not found. This confirms the test will exercise the to-be-written code.

- [ ] **Step 1.3: Implement AccountTheme.swift**

Create `Clave/Shared/AccountTheme.swift`:

```swift
import SwiftUI
import CryptoKit

/// Deterministic gradient palette for per-account visual identity.
///
/// Pubkey hex → SHA-256 → first 2 bytes → palette index. Same account
/// always gets the same gradient across launches and devices.
///
/// Used by AccountStripView (active pill ring), SlimIdentityBar (background
/// wash), HomeView (full-screen ambient gradient), AccountDetailView
/// (gradient banner header), ApprovalSheet (SigningAsHeader tint).
///
/// Palette is curated to avoid clashy hues, low-contrast pairs, and yellows
/// that look broken on white backgrounds. 12 entries — comfortably more than
/// the 5-account pairing cap, low collision probability for typical use.
struct AccountTheme: Equatable {
    let start: Color
    let end: Color
    let accent: Color
    let paletteIndex: Int  // exposed for tests + debugging

    /// Build a theme for a given account pubkey. Empty / invalid hex falls
    /// back to the first palette entry (defensive — should never fire in
    /// production since AppState guards against empty signerPubkeyHex).
    static func forAccount(pubkeyHex: String) -> AccountTheme {
        let normalized = pubkeyHex.lowercased()
        guard !normalized.isEmpty,
              normalized.allSatisfy({ $0.isHexDigit }) else {
            return palette[0]
        }
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let bytes = Array(digest)
        // Use first 2 bytes as a uint16, mod palette count for stable mapping.
        let index = (Int(bytes[0]) << 8 | Int(bytes[1])) % palette.count
        return palette[index]
    }

    /// 12 curated gradient pairs. Each entry: `(start, end, accent, index)`.
    /// Accent = darker / more saturated of the pair, used for text + active
    /// indicators. Indices are stable — never reorder this array (would
    /// reassign every existing account's color).
    static let palette: [AccountTheme] = [
        AccountTheme(start: Color(red: 0.48, green: 0.55, blue: 1.00),
                     end:   Color(red: 0.63, green: 0.29, blue: 1.00),
                     accent: Color(red: 0.35, green: 0.18, blue: 1.00),
                     paletteIndex: 0),  // purple/violet
        AccountTheme(start: Color(red: 0.00, green: 0.78, blue: 1.00),
                     end:   Color(red: 0.18, green: 1.00, blue: 0.71),
                     accent: Color(red: 0.00, green: 0.35, blue: 0.40),
                     paletteIndex: 1),  // teal/aqua
        AccountTheme(start: Color(red: 1.00, green: 0.55, blue: 0.29),
                     end:   Color(red: 1.00, green: 0.76, blue: 0.29),
                     accent: Color(red: 0.78, green: 0.35, blue: 0.00),
                     paletteIndex: 2),  // coral/amber
        AccountTheme(start: Color(red: 1.00, green: 0.29, blue: 0.55),
                     end:   Color(red: 1.00, green: 0.47, blue: 0.66),
                     accent: Color(red: 0.78, green: 0.10, blue: 0.40),
                     paletteIndex: 3),  // magenta/pink
        AccountTheme(start: Color(red: 0.29, green: 0.64, blue: 1.00),
                     end:   Color(red: 0.29, green: 0.91, blue: 1.00),
                     accent: Color(red: 0.10, green: 0.45, blue: 0.85),
                     paletteIndex: 4),  // sky/cyan
        AccountTheme(start: Color(red: 0.29, green: 1.00, blue: 0.55),
                     end:   Color(red: 0.76, green: 1.00, blue: 0.29),
                     accent: Color(red: 0.10, green: 0.55, blue: 0.20),
                     paletteIndex: 5),  // lime/grass
        AccountTheme(start: Color(red: 1.00, green: 0.42, blue: 0.42),
                     end:   Color(red: 1.00, green: 0.62, blue: 0.31),
                     accent: Color(red: 0.78, green: 0.18, blue: 0.18),
                     paletteIndex: 6),  // red/orange
        AccountTheme(start: Color(red: 0.55, green: 0.29, blue: 1.00),
                     end:   Color(red: 0.93, green: 0.42, blue: 1.00),
                     accent: Color(red: 0.40, green: 0.10, blue: 0.78),
                     paletteIndex: 7),  // violet/fuchsia
        AccountTheme(start: Color(red: 0.10, green: 0.78, blue: 0.60),
                     end:   Color(red: 0.40, green: 0.93, blue: 0.40),
                     accent: Color(red: 0.05, green: 0.40, blue: 0.30),
                     paletteIndex: 8),  // emerald/lime
        AccountTheme(start: Color(red: 0.78, green: 0.42, blue: 0.93),
                     end:   Color(red: 1.00, green: 0.55, blue: 0.78),
                     accent: Color(red: 0.55, green: 0.18, blue: 0.71),
                     paletteIndex: 9),  // orchid/pink
        AccountTheme(start: Color(red: 0.29, green: 0.42, blue: 0.85),
                     end:   Color(red: 0.55, green: 0.71, blue: 1.00),
                     accent: Color(red: 0.10, green: 0.20, blue: 0.65),
                     paletteIndex: 10), // navy/blue
        AccountTheme(start: Color(red: 1.00, green: 0.42, blue: 0.71),
                     end:   Color(red: 1.00, green: 0.71, blue: 0.42),
                     accent: Color(red: 0.78, green: 0.20, blue: 0.45),
                     paletteIndex: 11), // pink/peach
    ]
}
```

- [ ] **Step 1.4: Add file to ClaveTests target in Xcode**

Open `Clave.xcodeproj`, drag `ClaveTests/AccountThemeTests.swift` into the Xcode navigator under the ClaveTests group. Confirm "ClaveTests" target membership in the file inspector. The new `Clave/Shared/AccountTheme.swift` should already be auto-membered to the Clave target via the directory rule, but verify in the file inspector that "Clave" is checked (it must NOT be in ClaveNSE target — palette is main-app-only).

- [ ] **Step 1.5: Run tests, verify they pass**

Run: `xcodebuild -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4' test -only-testing:ClaveTests/AccountThemeTests 2>&1 | grep -E "Test Suite|passed|failed"`

Expected: All 6 tests pass. No failures.

- [ ] **Step 1.6: Commit**

```bash
git add Clave/Shared/AccountTheme.swift ClaveTests/AccountThemeTests.swift Clave.xcodeproj/project.pbxproj
git -c user.name="DocNR" -c user.email="thehypoxicdrive@gmail.com" commit -m "feat(stage-c): AccountTheme palette helper — hash-derived per-account gradients

Pure utility module: pubkey hex → SHA-256 → first 2 bytes → palette
index. 12 curated gradient entries (start, end, accent), stable indices
(never reorder). Empty/invalid hex falls back to palette[0] defensively.

6 unit tests cover: palette count, determinism, distribution, empty
input, invalid input, case-insensitivity. All pass on iOS 17 simulator.

Foundation for AccountStripView active pill ring, SlimIdentityBar wash,
HomeView ambient gradient, AccountDetailView banner, ApprovalSheet
SigningAsHeader."
git push origin feat/multi-account
```

---

## Task 2: AccountStripView + SlimIdentityBar + HomeView swap

**Files:**
- Create: `Clave/Views/Home/AccountStripView.swift`
- Create: `Clave/Views/Home/SlimIdentityBar.swift`
- Modify: `Clave/Views/Home/HomeView.swift` (replace `Menu`-wrapped identity bar from `aa194a9` with strip + slim bar; apply background gradient)

**Why no TDD here:** SwiftUI views — no meaningful unit-testable surface. Verification is build + simulator + on-device smoke.

### Step 2.1: Create AccountStripView

- [ ] **Step 2.1: Create `Clave/Views/Home/AccountStripView.swift`**

```swift
import SwiftUI

/// Horizontal scrolling avatar strip — Stage C account picker.
/// Replaces the build-37 interim Menu (`aa194a9`) on HomeView.
///
/// - Auto-hides when `accounts.count == 1` (single-account user sees same
///   Home as build 31; no UI noise).
/// - Active pill: 3pt gradient ring matching account's AccountTheme.
/// - Tap non-active pill → switchToAccount.
/// - Tap active pill → push AccountDetailView (via NavigationLink in HomeView).
/// - Long-press any pill → push AccountDetailView WITHOUT switching active.
/// - Trailing "+" pill → present AddAccountSheet (Task 3).
struct AccountStripView: View {
    @Environment(AppState.self) private var appState
    @Binding var showAddSheet: Bool

    /// Hardcoded — ring + pill sizing tuned per spec mockups (v4).
    private let pillSize: CGFloat = 38
    private let ringPadding: CGFloat = 3

    var body: some View {
        if appState.accounts.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(appState.accounts) { account in
                        accountPill(account)
                    }
                    addPill
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            }
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.white.opacity(0.4), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    // MARK: - Per-account pill

    @ViewBuilder
    private func accountPill(_ account: Account) -> some View {
        let isActive = account.pubkeyHex == appState.currentAccount?.pubkeyHex
        let theme = AccountTheme.forAccount(pubkeyHex: account.pubkeyHex)

        // NavigationLink wraps the inner content so tap on active pill pushes
        // AccountDetailView (Task 4). Non-active pill suppresses the link via
        // a separate Button overlay below.
        NavigationLink(value: AccountNavTarget.detail(pubkey: account.pubkeyHex)) {
            VStack(spacing: 4) {
                ZStack {
                    if isActive {
                        Circle()
                            .fill(LinearGradient(colors: [theme.start, theme.end],
                                                 startPoint: .topLeading,
                                                 endPoint: .bottomTrailing))
                            .frame(width: pillSize + ringPadding * 2,
                                   height: pillSize + ringPadding * 2)
                    }
                    avatarPlaceholder(for: account)
                        .frame(width: pillSize, height: pillSize)
                        .clipShape(Circle())
                }
                Text(labelText(for: account))
                    .font(.system(size: 9, weight: isActive ? .heavy : .semibold))
                    .foregroundStyle(isActive ? theme.accent : Color.primary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: pillSize + 8)
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            // Tap on non-active pill switches account instead of navigating.
            // For active pill, navigation runs (the NavigationLink wins).
            TapGesture().onEnded {
                if !isActive {
                    appState.switchToAccount(pubkey: account.pubkeyHex)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
        )
        .onLongPressGesture(minimumDuration: 0.5) {
            // Long-press always opens detail without switching, even on
            // active. Override the simultaneousGesture switch above by
            // doing nothing here — the NavigationLink fires on tap-up
            // only if the gesture wasn't a long-press, so explicit
            // navigation here on long-press requires programmatic push.
            // SwiftUI's NavigationLink(value:) consumes the tap; the
            // long-press fires before tap-up resolves. We rely on the
            // user performing the long-press THEN releasing — which iOS
            // treats as a long-press, not a tap, and the NavigationLink
            // doesn't fire. Trigger nav via app router state.
            appState.pendingDetailPubkey = account.pubkeyHex
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    // MARK: - Add pill

    private var addPill: some View {
        Button {
            showAddSheet = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .frame(width: pillSize, height: pillSize)
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }
                Text("Add")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: pillSize + 8)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    /// Avatar placeholder — letter on neutral gradient. Real PFPs from
    /// kind:0 picture URLs land here in a future iteration; for now we
    /// always show the letter.
    @ViewBuilder
    private func avatarPlaceholder(for account: Account) -> some View {
        let initial = String(labelText(for: account).first ?? "?").uppercased()
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.78), Color(white: 0.62)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
            Text(initial)
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(Color.white)
        }
    }

    /// Display label preference: petname → kind:0 displayName → truncated pubkey.
    private func labelText(for account: Account) -> String {
        if let p = account.petname, !p.isEmpty { return p }
        if let d = account.profile?.displayName, !d.isEmpty { return d }
        let h = account.pubkeyHex
        guard h.count > 8 else { return h }
        return String(h.prefix(8))
    }
}

/// Navigation target enum used by HomeView's NavigationStack to route
/// to AccountDetailView. Defined here because the strip is the primary
/// origin; SettingsView (Task 6) and the long-press handler also use it.
enum AccountNavTarget: Hashable {
    case detail(pubkey: String)
}
```

- [ ] **Step 2.2: Add `pendingDetailPubkey` to AppState**

In `Clave/AppState.swift`, find the published-properties section (top of class, around line 30-60 — adjacent to `accounts` and `currentAccount`):

Add this property:

```swift
/// Set by long-press on a strip pill; consumed by HomeView's
/// NavigationStack to push AccountDetailView for that account without
/// switching active. Cleared after navigation fires.
var pendingDetailPubkey: String?
```

- [ ] **Step 2.3: Create SlimIdentityBar**

Create `Clave/Views/Home/SlimIdentityBar.swift`:

```swift
import SwiftUI

/// Text-only identity row below AccountStripView. Shows current account's
/// `@petname • npub… [copy]`. No avatar (strip already shows it).
/// Background carries a 22% gradient wash matching the active account.
struct SlimIdentityBar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let current = appState.currentAccount {
            let theme = AccountTheme.forAccount(pubkeyHex: current.pubkeyHex)
            HStack(spacing: 10) {
                Text("@\(displayLabel(for: current))")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(.primary)
                Text(truncatedNpub(for: current))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                copyButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(LinearGradient(
                        colors: [theme.start.opacity(0.22), theme.end.opacity(0.16)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11)
                            .stroke(theme.start.opacity(0.35), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = appState.npub
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.92))
                        .shadow(color: Color.black.opacity(0.06), radius: 1, y: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func displayLabel(for account: Account) -> String {
        if let p = account.petname, !p.isEmpty { return p }
        if let d = account.profile?.displayName, !d.isEmpty { return d }
        return String(account.pubkeyHex.prefix(8))
    }

    private func truncatedNpub(for account: Account) -> String {
        let n = appState.npub
        guard n.count > 20 else { return n }
        return String(n.prefix(12)) + "…" + String(n.suffix(6))
    }
}
```

- [ ] **Step 2.4: Modify HomeView — replace Menu with strip + slim bar, apply background gradient**

In `Clave/Views/Home/HomeView.swift`, find the existing `identityBar` computed property (added in commit `aa194a9` — wraps a `Menu` around the avatar+name+npub). Replace it AND the surrounding view body to:

a. Remove the entire `identityBar` computed property (and the `accountLabel(_:)` helper next to it — moved into AccountStripView's `labelText(for:)`).
b. In the main `var body` of HomeView, replace the call site `identityBar` (it appeared inside a `VStack` near the top of the screen) with:

```swift
// Stage C: strip + slim bar replace the build-37 Menu identity bar.
AccountStripView(showAddSheet: $showAddAccountSheet)
SlimIdentityBar()
```

c. Add the `@State private var showAddAccountSheet = false` declaration near the other `@State` properties at the top of HomeView's struct.

d. Apply the full-screen background gradient. Find the outermost `NavigationStack { ... }` or `ZStack { ... }` body wrapper of HomeView. Wrap (or augment) it with the gradient overlay:

```swift
.background(homeBackgroundGradient.ignoresSafeArea())
```

Add the `homeBackgroundGradient` computed property:

```swift
private var homeBackgroundGradient: some View {
    let theme: AccountTheme
    if let current = appState.currentAccount {
        theme = AccountTheme.forAccount(pubkeyHex: current.pubkeyHex)
    } else {
        theme = AccountTheme.palette[0]
    }
    return LinearGradient(
        stops: [
            .init(color: theme.start.opacity(0.35), location: 0.0),
            .init(color: theme.end.opacity(0.22), location: 0.35),
            .init(color: theme.end.opacity(0.14), location: 0.70),
            .init(color: theme.start.opacity(0.10), location: 1.0),
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}
```

e. Add the navigationDestination for the strip-driven AccountDetailView push:

```swift
.navigationDestination(for: AccountNavTarget.self) { target in
    switch target {
    case .detail(let pubkey):
        AccountDetailView(pubkeyHex: pubkey)
    }
}
```

f. Add the long-press handler — observe `appState.pendingDetailPubkey` and push when set:

```swift
.onChange(of: appState.pendingDetailPubkey) { _, newValue in
    if newValue != nil {
        navigationPath.append(AccountNavTarget.detail(pubkey: newValue!))
        appState.pendingDetailPubkey = nil
    }
}
```

This requires HomeView to use a `NavigationStack(path: $navigationPath)` with `@State private var navigationPath = NavigationPath()`. If the existing NavigationStack uses the simpler form (no path binding), upgrade it to the path binding form here.

g. Add the AddAccountSheet presentation modifier (the sheet view itself ships in Task 3 — add the modifier here so the strip's `+` pill works the moment Task 3 lands):

```swift
.sheet(isPresented: $showAddAccountSheet) {
    AddAccountSheet()
}
```

If `AddAccountSheet` doesn't exist yet (it doesn't until Task 3), wrap this in `#if false ... #endif` for now OR temporarily replace `AddAccountSheet()` with `Text("Coming in Task 3")`. Recommended: temporarily use the placeholder Text so the build passes; Task 3.4 removes the placeholder.

- [ ] **Step 2.5: Build, verify clean**

Run: `xcodebuild -scheme Clave -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -3`

Expected: `** BUILD SUCCEEDED **`

If errors: most likely the `Account` model's `pendingDetailPubkey` addition wasn't recognized (check that AppState property is published / observable — it should auto-pick up since AppState is `@Observable` per Task 5 of Phase 1). If `AddAccountSheet` not found, ensure the placeholder is in place.

- [ ] **Step 2.6: Smoke in simulator**

Boot iPhone 17 simulator, run the app. Verify:
- Strip appears at top with all current accounts (test data should have ≥2 accounts; if not, switch to a multi-account state via dev menu).
- Active pill has gradient ring; non-active pills are bare.
- Slim bar below shows current `@petname • npub… [copy]` with subtle gradient wash.
- Tapping a non-active pill switches accounts; npub + slim bar wash + background gradient all shift.
- Tapping the `+` pill shows the placeholder text (or the AddAccountSheet skeleton if Task 3 already implemented).
- Single-account state: strip auto-hides; same Home as build 31 plus background gradient.

- [ ] **Step 2.7: Commit**

```bash
git add Clave/Views/Home/AccountStripView.swift Clave/Views/Home/SlimIdentityBar.swift Clave/Views/Home/HomeView.swift Clave/AppState.swift
git -c user.name="DocNR" -c user.email="thehypoxicdrive@gmail.com" commit -m "feat(stage-c): AccountStripView + SlimIdentityBar + HomeView gradient background

Replaces the interim Menu identity bar (aa194a9) with the C2 picker:
- AccountStripView: horizontal pills, active gets gradient ring,
  trailing + pill triggers AddAccountSheet, long-press pushes detail.
  Auto-hides when accounts.count == 1.
- SlimIdentityBar: text-only @petname • npub• copy with 22% gradient wash.
- HomeView: full-screen ambient gradient (35%→10% top-down) tied to
  active account's AccountTheme. NavigationStack path binding for
  programmatic detail push from long-press. AddAccountSheet sheet
  modifier with placeholder pending Task 3.

Bug G + Bug H wiring already in place from build 36/37 — switching via
strip triggers the existing refresh chain."
git push origin feat/multi-account
```

---

## Task 3: AddAccountSheet + remove the placeholder

**Files:**
- Create: `Clave/Views/Home/AddAccountSheet.swift`
- Modify: `Clave/Views/Home/HomeView.swift` (replace Task 2.4(g) placeholder with the real sheet)

### Step 3.1: Create AddAccountSheet

- [ ] **Step 3.1: Create `Clave/Views/Home/AddAccountSheet.swift`**

```swift
import SwiftUI

/// Modal sheet for adding a new account. Two modes via segmented control:
///   • Generate — random keypair, optional petname.
///   • Paste    — user-supplied nsec, optional petname.
///
/// Reuses existing AppState methods (generateAccount, addAccount). On
/// success, the new account becomes current automatically and the sheet
/// dismisses with a toast confirmation (toast wired in HomeView).
struct AddAccountSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable {
        case generate = "Generate new"
        case paste = "Paste nsec"
    }

    @State private var mode: Mode = .generate
    @State private var nsecInput: String = ""
    @State private var petnameInput: String = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if mode == .paste {
                    Section("Private key") {
                        SecureField("nsec1…", text: $nsecInput)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }

                Section("Petname (optional)") {
                    TextField("e.g. Personal", text: $petnameInput)
                        .autocorrectionDisabled()
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section {
                    Button(action: performAdd) {
                        HStack {
                            Spacer()
                            if isWorking {
                                ProgressView()
                            } else {
                                Text(mode == .generate ? "Generate" : "Add")
                                    .font(.headline)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isWorking || (mode == .paste && nsecInput.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
            .navigationTitle("Add Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func performAdd() {
        errorMessage = nil
        isWorking = true
        let petname = petnameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let petnameOrNil = petname.isEmpty ? nil : petname

        do {
            switch mode {
            case .generate:
                _ = try appState.generateAccount(petname: petnameOrNil)
            case .paste:
                let trimmed = nsecInput.trimmingCharacters(in: .whitespacesAndNewlines)
                _ = try appState.addAccount(nsec: trimmed, petname: petnameOrNil)
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        isWorking = false
    }
}
```

- [ ] **Step 3.2: Replace placeholder in HomeView**

In `Clave/Views/Home/HomeView.swift`, find the `.sheet(isPresented: $showAddAccountSheet) { ... }` modifier added in Task 2.4(g). Replace the placeholder (`Text("Coming in Task 3")`) with `AddAccountSheet()`.

- [ ] **Step 3.3: Build, verify clean**

Run: `xcodebuild -scheme Clave -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -3`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3.4: Smoke in simulator**

Boot simulator. Verify:
- Tap `+` pill → AddAccountSheet slides up.
- Mode picker switches between Generate / Paste.
- In Generate mode: tap Generate (no petname) → sheet dismisses, new account appears in strip and becomes active.
- In Paste mode: paste any non-nsec text → tap Add → red error message inline, sheet stays open.
- Cancel button dismisses without changes.

- [ ] **Step 3.5: Commit**

```bash
git add Clave/Views/Home/AddAccountSheet.swift Clave/Views/Home/HomeView.swift
git -c user.name="DocNR" -c user.email="thehypoxicdrive@gmail.com" commit -m "feat(stage-c): AddAccountSheet — minimal generate/paste add-account modal

Reuses existing AppState.generateAccount / addAccount (idempotent). Two
modes via segmented Picker: Generate (random keypair) and Paste (nsec).
Optional petname field. Inline error on invalid nsec. Auto-dismiss + new
account becomes active on success.

Triggered from AccountStripView's + pill (Task 2). Will also be triggered
by SettingsView Add Account row in Task 6."
git push origin feat/multi-account
```

---

## Task 4: AccountDetailView skeleton (banner + petname + delete only)

**Files:**
- Create: `Clave/Views/Settings/AccountDetailView.swift`

### Step 4.1: Create AccountDetailView shell

- [ ] **Step 4.1: Create `Clave/Views/Settings/AccountDetailView.swift`**

```swift
import SwiftUI

/// Per-account detail screen. Reachable from:
///   • AccountStripView active-pill tap (Task 2)
///   • AccountStripView long-press on any pill (Task 2, via pendingDetailPubkey)
///   • SettingsView Accounts section row tap (Task 6)
///
/// Skeleton in this task: gradient banner header + petname rename + delete.
/// Profile section + rotate-bunker + export-key + refresh-profile come in
/// Task 5.
struct AccountDetailView: View {
    let pubkeyHex: String

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var petnameInput: String = ""
    @State private var showDeleteAlert = false

    /// The Account this view is for. Reads from appState.accounts each time
    /// (auto-updates on rename / delete). nil if account was deleted while
    /// viewing — view dismisses on appearance of nil.
    private var account: Account? {
        appState.accounts.first { $0.pubkeyHex == pubkeyHex }
    }

    var body: some View {
        Form {
            // Banner appears as the first section's "header" so it gets
            // full-bleed treatment in Form / List. SwiftUI Form drops list
            // padding for clear sections we render manually.
            Section {
                EmptyView()
            } header: {
                if let account {
                    bannerHeader(for: account)
                        .listRowInsets(EdgeInsets())
                        .textCase(nil)
                }
            }

            if account != nil {
                petnameSection
                deleteSection
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            petnameInput = account?.petname ?? ""
        }
        .onChange(of: account == nil) { _, isNil in
            if isNil { dismiss() }
        }
        .alert("Delete \(deleteAlertNameSnippet)?",
               isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteAlertMessage)
        }
    }

    // MARK: - Banner

    @ViewBuilder
    private func bannerHeader(for account: Account) -> some View {
        let theme = AccountTheme.forAccount(pubkeyHex: account.pubkeyHex)
        ZStack(alignment: .leading) {
            LinearGradient(
                colors: [theme.start, theme.end],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            HStack(spacing: 14) {
                avatarLarge(for: account)
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName(for: account))
                        .font(.title3).fontWeight(.bold)
                        .foregroundStyle(.white)
                    Text(truncatedNpub(for: account))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                copyNpubButton(for: account)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 22)
        }
    }

    private func avatarLarge(for account: Account) -> some View {
        let initial = String(displayName(for: account).first ?? "?").uppercased()
        return ZStack {
            Circle()
                .fill(Color.white.opacity(0.25))
            Text(initial)
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(.white)
        }
        .frame(width: 56, height: 56)
        .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 2))
    }

    private func copyNpubButton(for account: Account) -> some View {
        Button {
            UIPasteboard.general.string = npubString(for: account)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(8)
                .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Petname

    private var petnameSection: some View {
        Section("Petname") {
            TextField("Display label", text: $petnameInput)
                .autocorrectionDisabled()
            if let account, petnameInput.trimmingCharacters(in: .whitespacesAndNewlines) != (account.petname ?? "") {
                Button("Save Petname") {
                    let trimmed = petnameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    appState.renamePetname(for: account.pubkeyHex,
                                            to: trimmed.isEmpty ? nil : trimmed)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
        }
    }

    // MARK: - Delete

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteAlert = true
            } label: {
                Label("Delete Account", systemImage: "trash")
            }
        } footer: {
            Text("Deletes the private key from this device and unpairs all clients on this account. This cannot be undone — back up your nsec first if you may need it later.")
                .font(.caption)
        }
    }

    private var deleteAlertNameSnippet: String {
        guard let account else { return "this account" }
        return "@\(displayName(for: account))"
    }

    private var deleteAlertMessage: String {
        guard let account else { return "" }
        let n = appState.accounts.firstIndex { $0.pubkeyHex == account.pubkeyHex }
            .flatMap { _ in appState.accounts.count }
        let pairs = SharedStorage.getConnectedClients(for: account.pubkeyHex).count
        let pairsClause = pairs == 0 ? "" : " and unpairs \(pairs) connection\(pairs == 1 ? "" : "s")"
        return "Permanently removes the key\(pairsClause). This cannot be undone."
    }

    private func performDelete() {
        guard let account else { return }
        appState.deleteAccount(pubkey: account.pubkeyHex)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        // dismissal happens via .onChange(of: account == nil) above
    }

    // MARK: - Helpers

    private func displayName(for account: Account) -> String {
        if let p = account.petname, !p.isEmpty { return p }
        if let d = account.profile?.displayName, !d.isEmpty { return d }
        return String(account.pubkeyHex.prefix(8))
    }

    private func npubString(for account: Account) -> String {
        guard let pk = try? PublicKey.parse(publicKey: account.pubkeyHex) else {
            return account.pubkeyHex
        }
        return (try? pk.toBech32()) ?? account.pubkeyHex
    }

    private func truncatedNpub(for account: Account) -> String {
        let n = npubString(for: account)
        guard n.count > 24 else { return n }
        return String(n.prefix(14)) + "…" + String(n.suffix(8))
    }
}
```

- [ ] **Step 4.2: Build, verify clean**

Run: `xcodebuild -scheme Clave -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -3`

Expected: `** BUILD SUCCEEDED **`

If errors: most likely missing imports — add `import NostrSDK` if `PublicKey.parse` is unresolved.

- [ ] **Step 4.3: Smoke in simulator**

Boot simulator. Verify:
- Tap active strip pill → AccountDetailView pushes; gradient banner shows correct color for active account.
- Long-press a non-active pill → AccountDetailView pushes for THAT account (not switching active). Active account in strip is unchanged.
- Petname field shows current petname; edit → "Save Petname" button appears; tap → strip pill label updates.
- Tap Delete Account → alert shows "Delete @<name>? Permanently removes the key and unpairs N connections..." → Cancel works → Delete (only if you have a disposable test account!) removes the account, view pops.

- [ ] **Step 4.4: Commit**

```bash
git add Clave/Views/Settings/AccountDetailView.swift
git -c user.name="DocNR" -c user.email="thehypoxicdrive@gmail.com" commit -m "feat(stage-c): AccountDetailView skeleton — gradient banner + petname rename + delete

Per-account detail screen. Skeleton scope: full-bleed gradient banner
header (avatar + name + npub + copy), petname rename via existing
renamePetname helper (audit A3 sanitization already in place), delete
account with named-account alert copy reusing existing deleteAccount
(audit A2 ordering).

Reachable from AccountStripView active-pill tap (NavigationLink) and
long-press (programmatic via appState.pendingDetailPubkey path append).
SettingsView entry point ships in Task 6.

Profile section + rotate-bunker + export-key + refresh-profile come in
Task 5."
git push origin feat/multi-account
```

---

## Task 5: AccountDetailView actions (rotate, export, refresh, profile)

**Files:**
- Modify: `Clave/AppState.swift` (extract `fetchProfile(for:)` private helper, add public `refreshProfile(for:)`)
- Modify: `Clave/Views/Settings/AccountDetailView.swift` (add Profile section + Actions section)

### Step 5.1: Refactor AppState — extract per-pubkey fetchProfile

- [ ] **Step 5.1: Extract `fetchProfile(for:)` helper in AppState**

In `Clave/AppState.swift`, find the existing `fetchProfileIfNeeded()` method (around line 820). Refactor:

a. Add a new private helper `private func fetchProfile(for pubkey: String) async` that contains the existing relay-fan-out + profile-update logic, but parameterized by `pubkey` instead of using `signerPubkeyHex`:

```swift
/// Fetch kind:0 profile for a SPECIFIC account pubkey. Used by both
/// fetchProfileIfNeeded() (current account, throttled) and
/// refreshProfile(for:) (any account, on-demand from AccountDetailView).
private func fetchProfile(for pubkey: String) async {
    let relays = [
        "wss://relay.powr.build",
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.primal.net",
        "wss://purplepag.es"
    ]

    await withTaskGroup(of: CachedProfile?.self) { group in
        for url in relays {
            group.addTask { await Self.fetchProfile(from: url, pubkey: pubkey) }
        }

        var newest: CachedProfile?
        for await result in group {
            guard let result else { continue }
            if newest == nil { newest = result; continue }
            if newest?.pictureURL == nil && result.pictureURL != nil { newest = result }
        }

        guard let cached = newest else { return }

        await MainActor.run {
            // Find the account by pubkey and update its .profile in place.
            if let idx = self.accounts.firstIndex(where: { $0.pubkeyHex == pubkey }) {
                self.accounts[idx] = Account(
                    pubkeyHex: self.accounts[idx].pubkeyHex,
                    petname: self.accounts[idx].petname,
                    addedAt: self.accounts[idx].addedAt,
                    profile: cached
                )
                self.persistAccounts()
                // If this is the current account, update the @Observable
                // `currentAccount` property too so views observing it re-render.
                if self.currentAccount?.pubkeyHex == pubkey {
                    self.currentAccount = self.accounts[idx]
                }
            }
        }

        // Bug F-fixed: cacheImage takes pubkey explicitly so the file
        // write goes to the right account's cache file regardless of
        // which account is current at write-time.
        if let pic = cached.pictureURL, !pic.isEmpty {
            await self.cacheImage(from: pic, pubkey: pubkey)
        }
    }
}
```

b. Modify the existing `fetchProfileIfNeeded()` to be a thin wrapper:

```swift
func fetchProfileIfNeeded() {
    let pubkey = signerPubkeyHex
    guard !pubkey.isEmpty else { return }

    // Only refetch if cache is older than 1 hour
    if let existing = profile, Date().timeIntervalSince1970 - existing.fetchedAt < 3600 { return }

    Task { await self.fetchProfile(for: pubkey) }
}
```

c. Add a new public method `refreshProfile(for: pubkey)` that bypasses the 1-hour throttle (since user explicitly tapped Refresh):

```swift
/// Force a profile refresh for any account, bypassing the 1-hour cache.
/// Called from AccountDetailView's "Refresh profile" action.
func refreshProfile(for pubkey: String) {
    guard !pubkey.isEmpty else { return }
    Task { await self.fetchProfile(for: pubkey) }
}
```

- [ ] **Step 5.2: Build, verify the AppState refactor compiles**

Run: `xcodebuild -scheme Clave -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -3`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5.3: Add Profile section to AccountDetailView**

In `Clave/Views/Settings/AccountDetailView.swift`, between the `petnameSection` and `deleteSection` in `body`, insert `profileSection` and `actionsSection`. Add these computed properties to the struct:

```swift
@ViewBuilder
private var profileSection: some View {
    if let account, let profile = account.profile {
        Section("Profile") {
            if let name = profile.displayName, !name.isEmpty {
                LabeledContent("Display name", value: name)
            }
            if let nip05 = profile.nip05, !nip05.isEmpty {
                LabeledContent("NIP-05", value: nip05)
            }
            if let lud16 = profile.lud16, !lud16.isEmpty {
                LabeledContent("Lightning address", value: lud16)
            }
            if let pic = profile.pictureURL, !pic.isEmpty {
                LabeledContent("Picture URL") {
                    Text(pic).font(.caption).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    } else if account != nil {
        Section("Profile") {
            Text("No profile published. Use Refresh below to fetch.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private var actionsSection: some View {
    Section("Actions") {
        if let account {
            Button {
                appState.refreshProfile(for: account.pubkeyHex)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Label("Refresh profile", systemImage: "arrow.clockwise")
            }

            Button {
                showRotateBunkerAlert = true
            } label: {
                Label("Rotate bunker secret", systemImage: "arrow.triangle.2.circlepath")
            }

            // Export only available for the CURRENT account (existing
            // ExportKeySheet uses the current keychain entry).
            if account.pubkeyHex == appState.currentAccount?.pubkeyHex {
                Button {
                    showExportSheet = true
                } label: {
                    Label("Export private key", systemImage: "key.viewfinder")
                }
            }
        }
    }
}
```

Add the corresponding state for the rotate-bunker alert + export sheet (near the existing `showDeleteAlert` declaration):

```swift
@State private var showRotateBunkerAlert = false
@State private var showExportSheet = false
```

Add the rotate-bunker alert + export sheet modifiers (chained after the existing delete alert modifier):

```swift
.alert("Rotate bunker secret for \(deleteAlertNameSnippet)?",
       isPresented: $showRotateBunkerAlert) {
    Button("Rotate") { performRotateBunker() }
    Button("Cancel", role: .cancel) {}
} message: {
    Text("Generates a new bunker URI for this account. Existing pairings continue working.")
}
.sheet(isPresented: $showExportSheet) {
    ExportKeySheet()
}
```

Add `performRotateBunker`:

```swift
private func performRotateBunker() {
    guard let account else { return }
    _ = SharedStorage.rotateBunkerSecret(for: account.pubkeyHex)
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
}
```

Wire `profileSection` + `actionsSection` into the body. Find the existing body and modify the conditional account check section:

```swift
if account != nil {
    profileSection      // NEW
    petnameSection
    actionsSection      // NEW
    deleteSection
}
```

- [ ] **Step 5.4: Build, verify clean**

Run: `xcodebuild -scheme Clave -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -3`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5.5: Smoke in simulator**

Boot simulator with a multi-account setup. Verify:
- Open AccountDetailView for an account that has a kind:0 profile → Profile section shows display name / NIP-05 / lud16 / picture URL.
- Open for an account without a profile → "No profile published. Use Refresh below to fetch."
- Tap "Refresh profile" → profile populates after a moment (relay fan-out).
- Tap "Rotate bunker secret" → alert with named copy → Rotate → no visible UI change but the bunker URI in ConnectSheet refreshes if you check (verify by going to Home → Connect for the same account).
- Tap "Export private key" (only on current account) → ExportKeySheet appears (existing biometric-gated flow).
- Switch active account; open detail for non-current → Export Key row hides.

- [ ] **Step 5.6: Commit**

```bash
git add Clave/AppState.swift Clave/Views/Settings/AccountDetailView.swift
git -c user.name="DocNR" -c user.email="thehypoxicdrive@gmail.com" commit -m "feat(stage-c): AccountDetailView Actions + Profile sections

AppState refactor: extract private fetchProfile(for: pubkey) helper +
add public refreshProfile(for:) that bypasses the 1-hour cache.
fetchProfileIfNeeded() becomes a thin wrapper. Bug F-fixed cacheImage
called with explicit pubkey so per-account cache files stay correct.

AccountDetailView additions:
- Profile section: read-only kind:0 fields (display name, NIP-05, lud16,
  picture URL). Empty state when no profile published.
- Actions section: Refresh profile (any account), Rotate bunker secret
  (any account, named alert copy), Export private key (current account
  only — existing biometric-gated ExportKeySheet).

Rotate-bunker alert reuses the named-account copy pattern: 'Rotate
bunker secret for @Alice? Existing pairings continue working.'"
git push origin feat/multi-account
```

---

## Task 6: SettingsView AccountsSection

**Files:**
- Modify: `Clave/Views/Settings/SettingsView.swift` (replace existing single-account "Signer Key" section with multi-account list + Add Account row)

### Step 6.1: Modify SettingsView

- [ ] **Step 6.1: Find the existing "Signer Key" section**

Open `Clave/Views/Settings/SettingsView.swift`. Locate the existing section that displays the current account's pubkey + a Register button (built around `appState.signerPubkeyHex`). It will look something like a `Section("Signer Key") { ... }` block. Note the line range — you'll replace it.

- [ ] **Step 6.2: Replace with AccountsSection**

Replace the entire "Signer Key" `Section { ... }` block with:

```swift
// Stage C: replaces the single-account "Signer Key" section.
Section("Accounts") {
    ForEach(appState.accounts) { account in
        NavigationLink(value: AccountNavTarget.detail(pubkey: account.pubkeyHex)) {
            HStack(spacing: 12) {
                accountAvatarSmall(for: account)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayLabelInSettings(for: account))
                        .font(.subheadline.bold())
                    Text(truncatedPubkey(account.pubkeyHex))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if account.pubkeyHex == appState.currentAccount?.pubkeyHex {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }
        }
    }
    Button {
        showAddSheet = true
    } label: {
        Label("Add Account", systemImage: "plus.circle")
    }
}
.sheet(isPresented: $showAddSheet) {
    AddAccountSheet()
}
.navigationDestination(for: AccountNavTarget.self) { target in
    switch target {
    case .detail(let pubkey):
        AccountDetailView(pubkeyHex: pubkey)
    }
}
```

Add `@State private var showAddSheet = false` to the struct's state.

Add the two helper methods:

```swift
@ViewBuilder
private func accountAvatarSmall(for account: Account) -> some View {
    let initial = String(displayLabelInSettings(for: account).first ?? "?").uppercased()
    let theme = AccountTheme.forAccount(pubkeyHex: account.pubkeyHex)
    ZStack {
        LinearGradient(colors: [theme.start, theme.end],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
        Text(initial)
            .font(.caption.bold())
            .foregroundStyle(.white)
    }
    .frame(width: 32, height: 32)
    .clipShape(Circle())
}

private func displayLabelInSettings(for account: Account) -> String {
    if let p = account.petname, !p.isEmpty { return p }
    if let d = account.profile?.displayName, !d.isEmpty { return d }
    return String(account.pubkeyHex.prefix(8))
}

private func truncatedPubkey(_ hex: String) -> String {
    guard hex.count > 16 else { return hex }
    return String(hex.prefix(8)) + "…" + String(hex.suffix(4))
}
```

- [ ] **Step 6.3: Verify SettingsView is still inside a NavigationStack**

The `.navigationDestination(for:)` modifier requires a NavigationStack ancestor. SettingsView's existing body should already be wrapped in `NavigationStack { ... }` (build-31 onwards uses one). If not, wrap the outermost view. Check via grep:

```bash
grep -n "NavigationStack" Clave/Views/Settings/SettingsView.swift
```

Expected: at least one match. If missing, wrap the body's root view in `NavigationStack { ... }`.

- [ ] **Step 6.4: Build, verify clean**

Run: `xcodebuild -scheme Clave -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -3`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6.5: Smoke in simulator**

Boot simulator. Verify:
- Settings tab → Accounts section lists all accounts (mini-avatar with account-themed gradient + petname/displayName + truncated pubkey + green checkmark on current).
- Tap any row → AccountDetailView pushes for that account.
- Tap Add Account → AddAccountSheet appears.
- Generate or paste a new account in the sheet → list updates immediately (Observable propagation).

- [ ] **Step 6.6: Commit**

```bash
git add Clave/Views/Settings/SettingsView.swift
git -c user.name="DocNR" -c user.email="thehypoxicdrive@gmail.com" commit -m "feat(stage-c): SettingsView Accounts section — list + Add Account row

Replaces the single-account 'Signer Key' section with a multi-account
NavigationLink list. Each row: themed mini-avatar + display label +
truncated pubkey + green checkmark on current. Trailing 'Add Account'
row presents AddAccountSheet (same sheet as the strip's + pill).

navigationDestination(for: AccountNavTarget.self) wires AccountDetailView
push, mirroring the HomeView strip path."
git push origin feat/multi-account
```

---

## Task 7: ApprovalSheet SigningAsHeader + destructive-copy updates

**Files:**
- Create: `Clave/Views/Home/SigningAsHeader.swift`
- Modify: `Clave/Views/Home/ApprovalSheet.swift` (prepend SigningAsHeader; update sign button copy to include account name)
- Modify: `Clave/Views/Home/ClientDetailView.swift` (update unpair alert copy to include named account)

### Step 7.1: Create SigningAsHeader

- [ ] **Step 7.1: Create `Clave/Views/Home/SigningAsHeader.swift`**

```swift
import SwiftUI

/// Mini-bar prepended to ApprovalSheet's body. Makes the active signer
/// account unmistakable so users don't approve a request for the wrong
/// account when multi-account is active.
///
/// Looks up the account from a pubkey hex (typically request.signerPubkeyHex);
/// falls back to a truncated pubkey when no Account / petname / displayName
/// is available.
struct SigningAsHeader: View {
    @Environment(AppState.self) private var appState
    let signerPubkeyHex: String

    var body: some View {
        let theme = AccountTheme.forAccount(pubkeyHex: signerPubkeyHex)
        let label = displayLabel()

        HStack(spacing: 10) {
            avatarMini
            HStack(spacing: 4) {
                Text("Signing as")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("@\(label)")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(LinearGradient(
                    colors: [theme.start.opacity(0.12), theme.end.opacity(0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(theme.start.opacity(0.4), lineWidth: 1)
                )
        )
    }

    private var avatarMini: some View {
        let theme = AccountTheme.forAccount(pubkeyHex: signerPubkeyHex)
        let initial = String(displayLabel().first ?? "?").uppercased()
        return ZStack {
            LinearGradient(colors: [theme.start, theme.end],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(initial)
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white)
        }
        .frame(width: 24, height: 24)
        .clipShape(Circle())
    }

    private func displayLabel() -> String {
        guard let account = appState.accounts.first(where: { $0.pubkeyHex == signerPubkeyHex }) else {
            // Defensive — request signer should always be in accounts.
            return String(signerPubkeyHex.prefix(8))
        }
        if let p = account.petname, !p.isEmpty { return p }
        if let d = account.profile?.displayName, !d.isEmpty { return d }
        return String(account.pubkeyHex.prefix(8))
    }
}
```

- [ ] **Step 7.2: Prepend SigningAsHeader to ApprovalSheet**

Open `Clave/Views/Home/ApprovalSheet.swift`. Find the outermost body view (typically a `VStack` or `ScrollView` inside a `NavigationStack`).

At the very top of that container, before the existing first content view, insert:

```swift
SigningAsHeader(signerPubkeyHex: pendingRequest.signerPubkeyHex.isEmpty
                                  ? appState.signerPubkeyHex
                                  : pendingRequest.signerPubkeyHex)
    .padding(.horizontal)
    .padding(.top, 12)
```

(Adjust `pendingRequest` to whatever the sheet's actual request property is named — probably `request` or `req`. The point is to use that request's `signerPubkeyHex`, falling back to the current account's hex if empty.)

- [ ] **Step 7.3: Update sign button / approval-action copy in ApprovalSheet**

Find the existing approval action button in ApprovalSheet. Update the button label / title text to incorporate the named account. Examples (adjust to match the existing structure):

If the existing button text is `"Approve"`:

```swift
Text("Sign as @\(displayLabelForRequest)")
```

Add a private helper:

```swift
private var displayLabelForRequest: String {
    let pk = pendingRequest.signerPubkeyHex.isEmpty
              ? appState.signerPubkeyHex
              : pendingRequest.signerPubkeyHex
    guard let account = appState.accounts.first(where: { $0.pubkeyHex == pk }) else {
        return String(pk.prefix(8))
    }
    if let p = account.petname, !p.isEmpty { return p }
    if let d = account.profile?.displayName, !d.isEmpty { return d }
    return String(account.pubkeyHex.prefix(8))
}
```

If the existing button is more complex (with kind labels etc.), adjust the title to incorporate `@\(displayLabelForRequest)` somewhere prominent — the spec example: `"Sign as @Alice: kind:1 note"`.

- [ ] **Step 7.4: Update unpair alert copy in ClientDetailView**

Open `Clave/Views/Home/ClientDetailView.swift`. Find the existing unpair confirmation alert (`.alert("Unpair Client?", isPresented: ..., ...)` or similar). Update the title and message to include the named account:

```swift
.alert(unpairAlertTitle, isPresented: $showUnpairConfirm) {
    Button("Unpair", role: .destructive) { performUnpair() }
    Button("Cancel", role: .cancel) {}
} message: {
    Text(unpairAlertMessage)
}
```

Add helpers:

```swift
private var unpairAlertTitle: String {
    let clientName = permissions?.name ?? "this connection"
    let accountLabel = currentAccountDisplayName
    return "Unpair \(clientName) from @\(accountLabel)?"
}

private var unpairAlertMessage: String {
    "This connection will no longer be able to sign for this account."
}

private var currentAccountDisplayName: String {
    guard let account = appState.currentAccount else {
        return String(appState.signerPubkeyHex.prefix(8))
    }
    if let p = account.petname, !p.isEmpty { return p }
    if let d = account.profile?.displayName, !d.isEmpty { return d }
    return String(account.pubkeyHex.prefix(8))
}
```

- [ ] **Step 7.5: Build, verify clean**

Run: `xcodebuild -scheme Clave -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -3`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7.6: Smoke in simulator**

Boot simulator. Verify:
- Trigger a protected-kind sign request (use a test client that signs kind:0 or any protected kind) → ApprovalSheet appears with SigningAsHeader at top showing "Signing as @<account>" with the matching gradient tint.
- Sign button reads "Sign as @<account>" or includes the account name in its label.
- Trigger an unpair from ClientDetailView (swipe-unpair on Home or detail-view unpair) → alert reads "Unpair <ClientName> from @<account>?"

- [ ] **Step 7.7: Commit**

```bash
git add Clave/Views/Home/SigningAsHeader.swift Clave/Views/Home/ApprovalSheet.swift Clave/Views/Home/ClientDetailView.swift
git -c user.name="DocNR" -c user.email="thehypoxicdrive@gmail.com" commit -m "feat(stage-c): ApprovalSheet SigningAsHeader + destructive-copy named accounts

SigningAsHeader: mini-avatar + 'Signing as @<account>' tinted bar
prepended to ApprovalSheet so multi-account users can't approve a
request for the wrong account. Looks up Account by request signerPubkeyHex.

Approval button copy now includes @<account> name. Unpair alert in
ClientDetailView now reads 'Unpair <ClientName> from @<account>?' to
make cross-account context explicit. Delete-account alert in
AccountDetailView (Task 4) already uses named copy.

Together with the gradient theming, makes destructive cross-account
actions hard to misread."
git push origin feat/multi-account
```

---

## Task 8: pbxproj bump 37→38 + archive build 38

**Files:**
- Modify: `Clave.xcodeproj/project.pbxproj` (8 instances of `CURRENT_PROJECT_VERSION = 37;` → `= 38;`)

### Step 8.1: Bump pbxproj

- [ ] **Step 8.1: Replace all CURRENT_PROJECT_VERSION = 37 with 38**

Use the Edit tool with `replace_all: true` on `Clave.xcodeproj/project.pbxproj`:

- old_string: `CURRENT_PROJECT_VERSION = 37;`
- new_string: `CURRENT_PROJECT_VERSION = 38;`

Then verify: `grep -c "CURRENT_PROJECT_VERSION = 38;" Clave.xcodeproj/project.pbxproj` — expected output: `8`

- [ ] **Step 8.2: Final build sanity**

Run: `xcodebuild -scheme Clave -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -3`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8.3: Run unit tests**

Run: `xcodebuild -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4' test 2>&1 | grep -E "Test Suite 'All tests'|Executed|TEST SUCCEEDED|TEST FAILED" | tail -5`

Expected: All tests pass (172 from before + 6 new AccountThemeTests = 178 total).

- [ ] **Step 8.4: Commit pbxproj bump**

```bash
git add Clave.xcodeproj/project.pbxproj
git -c user.name="DocNR" -c user.email="thehypoxicdrive@gmail.com" commit -m "build: bump pbxproj 37→38 for Stage C TestFlight

Build 38 carries Stage C UX (Tasks 1-7): AccountTheme palette,
AccountStripView + SlimIdentityBar, gradient HomeView background,
AddAccountSheet, AccountDetailView, SettingsView Accounts section,
ApprovalSheet SigningAsHeader + destructive named-copy updates.

Internal-TF only — URL flip still active. Prod rollout (PR #22 to prod
proxy + URL revert + final bump) gated on user comm to existing
build-31 testers per the 2026-05-02 hold."
git push origin feat/multi-account
```

- [ ] **Step 8.5: Archive build 38 (manual user step)**

The agent cannot drive Xcode's Archive UI. Hand off to the user:

> "Stage C is committed and pushed. To verify on device: in Xcode, **Product → Archive** (with target set to 'Any iOS Device (arm64)'). When the Organizer opens, click **Distribute App → App Store Connect → Upload**. After processing (~5 min), in App Store Connect TestFlight section, build 38 should appear under Internal Testing only — do NOT promote to External until prod rollout sequence runs."

- [ ] **Step 8.6: On-device smoke checklist (after install)**

Once the user installs build 38:

1. **Strip behavior**: tap each pill, verify Connected Clients + Activity refresh per account; long-press a non-active pill, verify AccountDetailView pushes for THAT account without switching active.
2. **Single-account auto-hide**: temporarily delete down to 1 account in dev menu; verify strip disappears and Home looks like build 31 + gradient.
3. **+ pill flow**: generate via AddAccountSheet → strip shows new pill, becomes active.
4. **Settings list**: tap Settings tab → Accounts section lists all → tap row → AccountDetailView opens → tap Add Account → same AddAccountSheet.
5. **AccountDetailView**: rename petname → reflects in strip + slim bar + Settings list immediately. Refresh profile → kind:0 fields populate. Rotate bunker → alert with named copy. Export key (current account only) → biometric prompt → ExportKeySheet.
6. **Theming**: switch through 4 accounts → background gradient + strip ring + slim-bar wash + active-tab text all shift to each account's hue.
7. **ApprovalSheet**: trigger a protected-kind sign request → "Signing as @<account>" header at top with tinted bar matching account gradient → sign button label includes @<account>.
8. **Unpair alert**: tap a client to unpair → alert reads "Unpair <ClientName> from @<account>?"
9. **Bug regression**: confirm bugs A-H stay fixed (account switching still refreshes Connected Clients + Activity per Bug H, PFP still refreshes per Bug G, etc.).

If anything fails, file the symptom + commit hash; agent triages.

---

## Self-Review

After writing this plan, verifying against the spec:

**1. Spec coverage:**

| Spec section | Implemented in |
|---|---|
| C2 picker (strip + slim bar) | Task 2 |
| Auto-hide strip when accounts.count == 1 | Task 2.1 (AccountStripView body conditional) |
| Active pill ring + bold label | Task 2.1 |
| Tap non-active pill → switch | Task 2.1 (simultaneousGesture on TapGesture) |
| Tap active pill → AccountDetailView | Task 2.1 (NavigationLink wraps content) |
| Long-press → AccountDetailView w/o switching | Task 2.1 (onLongPressGesture + pendingDetailPubkey) |
| `+` pill → AddAccountSheet | Task 2.1 (Button) + Task 3 (sheet content) |
| Slim bar (text-only `@petname • npub [copy]`) | Task 2.3 |
| Slim bar 22% gradient wash | Task 2.3 |
| HomeView full-screen background gradient | Task 2.4(d) |
| AccountTheme hash-derived palette | Task 1 |
| 12-entry palette | Task 1.3 |
| Deterministic mapping | Task 1.3 + Task 1.1 (test) |
| Empty/invalid hex fallback | Task 1.3 (guard) + Task 1.1 (tests) |
| AccountDetailView gradient banner | Task 4 |
| AccountDetailView profile section | Task 5 |
| AccountDetailView petname rename | Task 4 |
| AccountDetailView rotate-bunker alert (named copy) | Task 5 |
| AccountDetailView export key (current only) | Task 5 |
| AccountDetailView delete (named alert copy) | Task 4 |
| AccountDetailView refresh profile | Task 5 (uses new refreshProfile helper) |
| AppState fetchProfile(for:) refactor | Task 5.1 |
| AppState refreshProfile(for:) public method | Task 5.1 |
| SettingsView Accounts section | Task 6 |
| Settings → AccountDetailView nav | Task 6 |
| Settings Add Account row → AddAccountSheet | Task 6 |
| ApprovalSheet SigningAsHeader | Task 7 |
| ApprovalSheet sign button named copy | Task 7.3 |
| ClientDetailView unpair named copy | Task 7.4 |
| AddAccountSheet generate / paste modes | Task 3 |
| AddAccountSheet error handling | Task 3.1 (errorMessage state + catch block) |
| AddAccountSheet auto-switch on success | Task 3.1 (existing addAccount/generateAccount handles) |
| pbxproj 37→38 | Task 8 |
| Internal-TF only / URL flip retained | Task 8.4 (commit message) |

**No spec gaps. Every approved design element has a task.**

**2. Placeholder scan:** No "TBD", "TODO", "implement later", "fill in details", or vague-action placeholders. Every code step has full Swift / shell / commit content.

**3. Type consistency check:**

- `AccountTheme.forAccount(pubkeyHex:)` — Task 1.3, used in Tasks 2.1, 2.3, 2.4, 4.1, 5.3, 6.2, 7.1 ✓
- `AccountTheme.palette` — Task 1.3, used in Task 2.4(d) (`palette[0]` fallback) ✓
- `AccountTheme.start / end / accent` — Task 1.3, used in Tasks 2.1, 2.3, 2.4, 4.1, 6.2, 7.1 ✓
- `AccountTheme.paletteIndex` — Task 1.3, used in Task 1.1 tests ✓
- `AccountNavTarget.detail(pubkey:)` — Task 2.1, used in Tasks 2.4(e), 6.2 ✓
- `appState.pendingDetailPubkey` — Task 2.2, used in Tasks 2.1, 2.4(f) ✓
- `appState.refreshProfile(for:)` — Task 5.1, used in Task 5.3 ✓
- `AddAccountSheet()` — Task 3.1, used in Tasks 2.4(g), 3.2, 6.2 ✓
- `AccountDetailView(pubkeyHex:)` — Task 4.1, used in Tasks 2.4(e), 6.2 ✓
- `SigningAsHeader(signerPubkeyHex:)` — Task 7.1, used in Task 7.2 ✓

All identifiers consistent across tasks.

---

## Plan complete

Plan saved to `docs/superpowers/plans/2026-05-01-stage-c-multi-account-ux.md`. Two execution options:

1. **Subagent-Driven (recommended)** — Dispatch a fresh subagent per task, review between tasks, fast iteration. Each task gets its own fresh context window so the implementing agent isn't loaded with brainstorm history.
2. **Inline Execution** — Execute tasks in the current session using `superpowers:executing-plans`, batch execution with checkpoints for review.

Pick one to start implementation.
