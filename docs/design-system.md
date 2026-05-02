# Clave Design System

_Last updated: 2026-05-02. Derived from the Home tab redesign that shipped on `feat/multi-account`. Covers visual tokens, layout patterns, and code conventions._

The Home tab is the reference implementation. When extending to other surfaces (ConnectSheet, AccountDetailView redesigns, etc.), reach for these tokens and patterns first; deviate only with a written reason.

## Cross-platform applicability

This doc is the source of truth for Clave's design language across the iOS app and the [clave.casa](https://github.com/DocNR/clave-casa) web companion. iOS is the reference implementation. clave.casa already mirrors `Shared/AccountTheme.swift`'s palette + SHA-256 hash mapping byte-for-byte and the `displayLabel` resolution rule.

| Carries directly to clave.casa | iOS-only (needs platform equivalent) |
|---|---|
| AccountTheme palette (RGB values) | SwiftUI modifiers (`.listSectionSpacing`, `.scrollContentBackground`, etc.) |
| displayLabel resolution rule (petname → displayName → prefix(8)) | Haptics map (`UIImpactFeedbackGenerator`) — translate to subtle animation / sound on web |
| Identity-zone vs functional-zone philosophy | Sheet conventions (`.presentationBackground`, detents) — translate to modal/dialog patterns on web |
| Avatar treatments (cached PFP with opaque backing, pubkey-hue placeholder, white-on-translucent on saturated bg) | Toolbar conventions (NavigationBar) — translate to web header |
| Spacing ratios (proportions translate; pt → px or rem on web) | Specific SwiftUI Section/List structure |
| Copy patterns + cap dialog strings (sourced from `AccountError`) | Pre-check pattern uses Swift closures; web uses event handlers / route guards |
| Anti-patterns (white-on-grey, transparent PFP without backing, etc.) | iOS-specific bug recovery details |

When in doubt: visual *tokens* (color, type, spacing) are universal; *chrome conventions* (sheets, toolbars, haptics) need translation.

---

## 1. Philosophy

Two conceptual zones:

**Identity zone** — the top section of any account-scoped surface. Carries per-account visual identity through the AccountTheme gradient. Avatars, ring colors, slim-banner backgrounds, ambient screen gradient, AccountDetailView banner all live here. Saturated colors are appropriate; text is white.

**Functional zone** — content rows, lists, settings, sheets. System-adaptive colors (`.primary`, `.secondary`, `Color(.systemBackground)`). Avoids hardcoded white/black; respects light/dark mode automatically.

The identity zone tells the user *which account* they're operating as. The functional zone tells them *what to do*. Don't blur the line.

---

## 2. Color & theme

### AccountTheme (per-account identity)

`Shared/AccountTheme.swift` defines a 12-entry palette deterministically mapped from `pubkeyHex` via SHA-256 → first 2 bytes → `% palette.count`. Same account always gets the same theme.

```swift
let theme = AccountTheme.forAccount(pubkeyHex: account.pubkeyHex)
// theme.start, theme.end → gradient colors
// theme.accent       → darker / more saturated; used for text + active indicators
// theme.paletteIndex → for tests + debugging only
```

**Stability rules** (load-bearing — break these and existing accounts get reassigned colors):
- Never reorder palette entries
- Never insert mid-array and renumber
- Append-only at the end is safe
- Refining colors *within* an existing index is acceptable; breaking the index → pubkey mapping is not

**Defensive guards:**
- `pubkeyHex.count == 64` length check
- `allSatisfy({ $0.isHexDigit })`
- Falls back to `palette[0]` for empty/malformed/wrong-length input

### When to use which theme color

| Surface | Color | Notes |
|---|---|---|
| Active strip pill ring | `LinearGradient([theme.start, theme.end], topLeading → bottomTrailing)` | 5pt thick |
| Active strip pill label | `theme.accent` | `.heavy` weight |
| Slim banner background | Solid `LinearGradient([theme.start, theme.end])` | No opacity; with 0/1/8 shadow at `theme.start.opacity(0.25)` |
| AccountDetailView banner | Solid `LinearGradient([theme.start, theme.end])` | Full-bleed |
| HomeView ambient gradient | `LinearGradient` with opacity stops 38/26/16/8, top → bottom | See §6 |
| Pair New Connection icon backing | Solid `Circle().fill(theme.accent)` | White SF Symbol on top |
| Inactive strip pill ring | **NOT THEMED** — uses `Color.secondary.opacity(0.25)` 1pt stroke | All inactive pills look the same; only active pulls theme |

**Don't** apply theme colors to functional-zone elements (list rows, sheet backgrounds, system buttons). The theme is for identity, not chrome.

### System / adaptive colors

For everything outside the identity zone, use system colors. They auto-adapt to light/dark.

| Token | Use for |
|---|---|
| `.primary` | Primary text on neutral backgrounds (list rows, headlines) |
| `.secondary` | Supporting text, captions, inactive states |
| `.tertiary` | Empty-state hints, very subtle text |
| `Color(.systemBackground)` | Opaque backing behind PFPs (transparent images would otherwise reveal the gradient ring); white in light, black in dark |
| `Color(.systemGroupedBackground)` | Solid sheet presentation background; matches Form's grouped style |
| `Color(.systemGray6)` | Card-style row backgrounds in functional zone (e.g. ConnectSheet sections) |

**Cautionary tale: white-on-grey.** ConnectSheet's bunker URI text was once `.foregroundStyle(.white)` over `Color(.systemGray6).opacity(0.3)` — invisible in light mode (light grey on near-white). Fixed in `1a06290` to `.foregroundStyle(.primary)`. **Never hardcode `.white` text on a system background.** White is appropriate over saturated theme gradients; otherwise use `.primary`.

### Pubkey-hue derivation (fallback avatars)

When no PFP is cached, `AvatarView` (`Clave/Views/Components/AvatarView.swift`) generates a unique gradient from `pubkeyHex.prefix(12)`:

```swift
let hue1 = Double(hexValue(bytes, offset: 0)) / 255.0
let hue2 = Double(hexValue(bytes, offset: 4)) / 255.0
LinearGradient(colors: [
    Color(hue: hue1, saturation: 0.7, brightness: 0.9),
    Color(hue: hue2, saturation: 0.6, brightness: 0.7)
], startPoint: .topLeading, endPoint: .bottomTrailing)
```

Yields ~65k unique gradient combinations (vs the 12-entry AccountTheme palette). Use AvatarView for any avatar slot that may be empty: strip pill placeholder, ConnectedClient row avatars, etc.

---

## 3. Typography

iOS system font; no custom typefaces. Sizes are precise — small variances read as wrong on device.

| Element | Style | Weight |
|---|---|---|
| Toolbar title ("Clave") | `.system(size: 17)` | system default (inline mode) |
| Strip pill label (active) | `.system(size: 11)` | `.heavy` |
| Strip pill label (inactive) | `.system(size: 11)` | `.semibold` |
| Strip "Add" pill label | `.system(size: 11)` | `.semibold` |
| Strip pill avatar initial (via `AvatarView`) | `.system(size: size * 0.35)` mono (pubkey fallback) or `.system(size: size * 0.4)` proportional (name initials) | `.bold` |
| Slim banner petname | `.system(size: 14)` | `.heavy` |
| Slim banner npub | `.system(size: 9.5, design: .monospaced)` | `.medium` |
| Slim banner mini-avatar initial | `.system(size: 13)` | `.heavy` |
| AccountDetailView banner displayName | `.title3` | `.bold` |
| AccountDetailView banner npub | `.system(.caption, design: .monospaced)` | default |
| AccountDetailView avatar initial | `.system(size: 22)` | `.heavy` |
| Section header ("Connected Clients") | `.headline` | system |
| Stats card value | `.title2` | `.bold` |
| Stats card title | `.caption2` | system |
| List row title | `.subheadline` | `.bold` |
| List row caption | `.caption` | system |
| Empty-state hint | `.subheadline` | system |

**Monospaced** for npub strings and other hex/key data. `.system(.caption, design: .monospaced)` adapts to dynamic type; `.system(size: 9.5, design: .monospaced)` is fixed (use only when a fixed size is required).

**Foreground on theme gradients** is always `.white` (banner, slim-banner, active ring icon). Inside the identity zone, white-on-saturated-color is the contrast story.

---

## 4. Avatars

Three treatments. Pick by context.

### A. Cached PFP (real photo from kind:0)

```swift
ZStack {
    Color(.systemBackground)         // opaque backing
    Image(uiImage: cachedImage)
        .resizable()
        .scaledToFill()
}
.frame(width: size, height: size)
.clipShape(Circle())
```

**Critical:** the `Color(.systemBackground)` backing is non-negotiable. PFPs with transparent backgrounds (robohash, some kind:0 avatars) would otherwise let the gradient ring bleed through the avatar, making the silhouette indistinguishable from the ring. The backing adapts (white in light, black in dark) so it's ring-distinct in both modes.

Cache file: `<app-group-container>/cached-profile-<pubkeyHex>.dat`. Read synchronously in view body — files are small (~50KB).

### B. Pubkey-hue placeholder (no PFP, neutral background)

Use `AvatarView`:

```swift
AvatarView(pubkeyHex: account.pubkeyHex,
           name: account.displayLabel,
           size: pillSize)
```

Generates unique gradient + initials (`size * 0.35` monospaced when falling back to pubkey prefix; `size * 0.4` proportional when using `name` initials, up to two letters: "AL" for "Alice", "JB" for "Joe Bloggs"). Prefer over a flat-color placeholder.

### C. Letter-on-translucent (sitting on a saturated theme gradient)

For mini avatars *inside* the slim banner or AccountDetailView's banner, where the surface is already a saturated theme gradient. Treatment B's pubkey-hue gradient would clash; flat white with translucency reads cleanly.

```swift
ZStack {
    Color.white.opacity(0.22)
    Text(initial)
        .font(.system(size: size * 0.46, weight: .heavy))
        .foregroundStyle(.white)
}
.frame(width: size, height: size)
.clipShape(Circle())
.overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: borderWidth))
```

Single character only (`displayLabel.first`), unlike treatment B's 1-2 letter rule. Border thickness scales with diameter (~5% — 1.5pt at 28pt mini, 2pt at 56pt banner avatar).

### Treatment selection rule

| Context | Treatment |
|---|---|
| Cached PFP exists (any surface) | A — Image + opaque backing |
| Empty PFP, sitting on neutral / system background (strip pills, ConnectedClient rows) | B — AvatarView pubkey-hue |
| Empty PFP, sitting on saturated theme gradient (slim banner, AccountDetailView banner) | C — letter-on-white-22% |

### Sizing scale

| Slot | Diameter | Initial font | Border |
|---|---|---|---|
| Strip pill avatar | 60pt (active ring + 5pt padding each side) | `size * 0.35` mono / `size * 0.4` proportional (via AvatarView) | none on avatar; ring is the frame |
| Slim banner mini-avatar | 28pt | 13pt heavy (~`size * 0.46`) | 1.5pt white-40% |
| AccountDetailView banner avatar | 56pt | 22pt heavy (~`size * 0.39`) | 2pt white-40% |
| Connected Clients row avatar | 32pt | via AvatarView (size * 0.35 / 0.4) | none |
| Settings accounts row avatar | 32pt | via AvatarView | none |

Treatment-C avatars (slim banner, AccountDetailView) use slightly looser font ratios than AvatarView's because they render a single character at a fixed visual weight; the ratio "feels right" rather than scaling mathematically. Border thickness scales linearly with diameter at ~5%.

---

## 5. Spacing & layout

### Strip (`AccountStripView`)

```
pillSize:       60
ringPadding:    5    (so active pill takes 70pt total)
HStack spacing: 14
.padding(.horizontal, 14)
.padding(.vertical,   12)
```

No frosted card, no background — pills sit directly on `HomeView`'s ambient gradient.

### Slim banner (`SlimIdentityBar`)

```
.padding(.horizontal, 16)        // inner
.padding(.vertical,   12)        // inner
RoundedRectangle(cornerRadius: 12)
.shadow(color: theme.start.opacity(0.25), radius: 8, x: 0, y: 1)
.padding(.horizontal, 14)        // outer
.padding(.bottom,     12)        // outer — single source of truth
```

`SlimIdentityBar` owns its own outer bottom padding; consumers (HomeView) must NOT add `.padding(.bottom, ...)` on the invocation site or you get double-counted spacing.

Tap target = entire row (wrapped in a Button). Copy button is a nested Button — iOS handles the gesture priority. Tapping the copy area copies the npub; tapping anywhere else pushes AccountDetailView.

### List sections

```swift
.listStyle(.plain)
.listSectionSpacing(0)            // not .compact — 0 is what the design wants
.scrollContentBackground(.hidden) // so HomeView's gradient shows through
```

For sections in the identity zone (strip + slim banner + stats):
```swift
.listRowInsets(EdgeInsets())
.listRowBackground(Color.clear)
.listRowSeparator(.hidden)
```

For functional-zone sections (Connected Clients):
```swift
} header: {
    Text("Connected Clients")
        .font(.headline)
        .foregroundStyle(.primary)
        .textCase(nil)   // override default ALL-CAPS section header
}
```

### Stats row (the gradient-zone "in-between" surface)

The 3-card stats row sits in the identity gradient zone but uses `.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))` for each card. Material is acceptable here because the cards are small inline elements (not a wrapper around the identity strip) — they let the ambient gradient bleed through while remaining legibly grouped.

**Rule:** `.ultraThinMaterial` is OK on small inline cards within the gradient zone (stat cards, status pills, etc.). It is NOT OK as a wrapper around identity elements — that's how we got the build-38 frosted-card-around-the-strip that the redesign deleted.

Stats row internal layout: `HStack(spacing: 12)`, `.padding(.horizontal)` on the row, no internal bottom padding. Section spacing carries the gap to the next section.

### AccountDetailView banner

```
.padding(.horizontal, 18)
.padding(.vertical,   22)
```

Banner is rendered as a Section header so it gets full-bleed treatment in Form. The section's content is `EmptyView()`; the banner does the work.

---

## 6. HomeView ambient gradient

The screen background carries the active account's identity even outside the strip:

```swift
LinearGradient(
    stops: [
        .init(color: theme.start.opacity(0.38), location: 0.0),
        .init(color: theme.end.opacity(0.26),   location: 0.35),
        .init(color: theme.end.opacity(0.12),   location: 0.70),
        .init(color: theme.start.opacity(0.06), location: 1.0),
    ],
    startPoint: .top,
    endPoint:   .bottom
)
.ignoresSafeArea()
```

Apply on the NavigationStack root (NOT the List), and pair with `.scrollContentBackground(.hidden)` on the List or the gradient won't show.

Animate transitions on account switch:
```swift
.animation(.easeInOut(duration: 0.3), value: appState.currentAccount?.pubkeyHex)
```

**Defensive fallback** when `appState.currentAccount == nil` (first launch, post-import edge cases): use `AccountTheme.palette[0]` so the screen never renders gradient-less. The fallback should never fire in normal use; AppState guards against empty signerPubkeyHex elsewhere.

**Don't** put this gradient on functional-zone surfaces (sheets, settings views). It belongs to the Home identity zone.

---

## 7. Components

### Pre-check + sheet pattern

Any UI entry point that opens a sheet for "add X" should pre-check the cap *before* opening. Don't make the user fill in a form and then tell them they're at the limit.

```swift
private func handleAddAccountTap() {
    if appState.accounts.count >= Account.maxAccountsPerDevice {
        showAccountCapAlert = true
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    } else {
        showAddAccountSheet = true
    }
}
```

Same for connection-add (`handlePairNewConnectionTap`). Defense-in-depth at AppState/wire boundaries (ApprovalSheet, LightSigner) catches anything that bypasses the UI tap path (e.g. a NIP-46 connect arriving from another device while at cap).

Sheet body keeps a fallback alert with the same copy in case a future caller skips the pre-check.

### Closure handoff (parent owns routing)

Subviews that *trigger* a flow shouldn't *decide* it. Pass a closure; let the parent decide.

```swift
// AccountStripView
struct AccountStripView: View {
    let onAddTapped: () -> Void   // not @Binding showAddSheet: Bool
    // ...
    private var addPill: some View {
        Button { onAddTapped() } label: { ... }
    }
}

// HomeView
AccountStripView(onAddTapped: handleAddAccountTap)
```

Lets HomeView intercept with the cap pre-check. A `@Binding Bool` would force the subview to make the routing decision.

### Identity-zone navigation

Tapping the active pill or the slim banner pushes AccountDetailView. Both go through `appState.pendingDetailPubkey` which HomeView's NavigationStack `onChange` consumes:

```swift
appState.pendingDetailPubkey = account.pubkeyHex
// HomeView does:
.onChange(of: appState.pendingDetailPubkey) { _, newValue in
    if let pubkey = newValue {
        navigationPath.append(AccountNavTarget.detail(pubkey: pubkey))
        appState.pendingDetailPubkey = nil
    }
}
```

This avoids putting NavigationLink inside Buttons (gesture conflicts) and gives a single hook for any "open detail for X" trigger.

### `Account.displayLabel`

Single source of truth for display name resolution:

```swift
extension Account {
    var displayLabel: String {
        if let p = petname, !p.isEmpty { return p }
        if let d = profile?.displayName, !d.isEmpty { return d }
        return String(pubkeyHex.prefix(8))
    }
}
```

Use `account.displayLabel` everywhere — strip labels, banner names, copy strings, alerts. **Don't** re-implement the petname → displayName → prefix(8) chain inline. (Found and consolidated 9 inline copies in commit `eb42583`.)

### Cap constants (single source of truth)

```swift
extension Account {
    static let maxAccountsPerDevice: Int = 4
    static let maxClientsPerAccount: Int = 5
}

enum AccountError: LocalizedError {
    case accountCapReached
    case connectionCapReached
    var errorDescription: String? { ... }
}
```

UI alerts source their message from `AccountError.errorDescription` so a copy change happens in one place. Wire-level error responses (e.g. NIP-46 over the wire to a connecting client) use simpler English since the audience is a different app, not the user.

### State variable naming

Cap-alert state vars follow this convention:
- `showCapAlert` — when the surface only handles ONE kind of cap (AddAccountSheet, SettingsView Add-Account row both only deal with the account cap).
- `showAccountCapAlert` / `showConnectionCapAlert` — when the surface handles MULTIPLE caps and disambiguation matters (HomeView routes both).
- ApprovalSheet uses `showConnectionCapAlert` since it only deals with the connection cap; the explicit name aligns with HomeView's convention.

---

## 8. Sheets & toolbars

### Sheet conventions

```swift
SomeSheet()
    .presentationDetents([.medium, .large])
    .presentationBackground(Color(.systemGroupedBackground))
```

`.presentationBackground` is critical. The default is translucent — distracting on real device. Always set to a system background.

Cancel button in `.cancellationAction`:
```swift
.toolbar {
    ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
    }
}
```

Form-style content uses native `Section`, `Picker`, `TextField`, etc. — don't fight the system.

### Toolbar conventions

For account-scoped main screens (Home):
```swift
.navigationTitle("Clave")
.navigationBarTitleDisplayMode(.inline)
```

No `+` buttons in nav bar (caused confusion when stacked next to the strip's `+` pill). Use inline rows instead (`pairNewConnectionRow` at the top of Connected Clients).

For detail screens:
```swift
.navigationTitle("Account")
.navigationBarTitleDisplayMode(.inline)
```

---

## 9. Copy patterns

### Named-account destructive copy

When confirming destructive actions, name the account explicitly:

```swift
.alert("Delete @\(account.displayLabel)?", isPresented: $showDeleteAlert)
.alert("Rotate bunker secret for @\(account.displayLabel)?", isPresented: $showRotateAlert)
.alert("Unpair Nostur from @\(account.displayLabel)?", isPresented: ...)
```

The `@` prefix matches the slim banner / strip label format. Reads as "are you sure you want to do X to *this specific account*?" rather than ambiguous "are you sure?" prompts.

### Connection-count footers

For destructive-with-side-effects copy:
```
"Permanently removes the key and unpairs N connection[s]. This cannot be undone."
```

`appState.getConnectedClients(for: pubkey).count` is cheap; surface it in the confirmation copy so the user knows what else is going away.

### Cap-reached copy

Sourced from `AccountError.errorDescription`:
- Account: `"You can have up to N accounts on this device. More accounts will be available in the future."`
- Connection: `"You can pair up to N clients per account. Unpair one in Settings → Clients to continue. More connections will be available in the future."`

**Never** say "subscription" or "premium" in user-facing copy. The phrase "available in the future" is intentionally vague — leaves room for either a free expansion or a paid tier without rewriting strings.

### Refresh copy

`"Refresh profile"` (verb + noun), not just `"Refresh"`. Lives inline at the bottom of the Profile section, not in a separate Actions section.

### Empty states

`"No clients connected"` (state) + `"Connect a Nostr client like Nostur or noStrudel to start signing events remotely."` (action hint). Keep hint concrete — name actual clients the user might know.

---

## 10. Haptics map

```swift
UIImpactFeedbackGenerator(style: .light).impactOccurred()
UIImpactFeedbackGenerator(style: .medium).impactOccurred()
UINotificationFeedbackGenerator().notificationOccurred(.success)
UINotificationFeedbackGenerator().notificationOccurred(.warning)
UINotificationFeedbackGenerator().notificationOccurred(.error)
```

| Event | Haptic |
|---|---|
| Switch account (strip pill tap) | `.light` |
| Push detail (active pill, slim banner, long-press) | `.medium` |
| Copy npub / bunker URI | `.light` |
| Open AddAccountSheet `+` pill | `.light` |
| Save petname | `.light` |
| Rotate bunker secret | `.medium` |
| Add account success | `.success` |
| Add account failure (parse error, etc.) | `.error` |
| Cap-reached blocked action | `.warning` |
| Delete account confirmed | `.warning` |

Don't haptic for navigation (back button, tab switch) — iOS handles those. Haptic when *something happens* the user cared about: state mutation, content copied, action blocked.

---

## 11. Anti-patterns

These were caught and fixed during the Stage C polish session. Don't reintroduce them.

### Hardcoded `.white` on system backgrounds

```swift
// ❌ Invisible in light mode
Text(uri).foregroundStyle(.white).background(Color(.systemGray6))

// ✅ Adapts
Text(uri).foregroundStyle(.primary).background(Color(.systemGray6))
```

White is appropriate on saturated theme gradients (banner, slim banner, active ring). On any neutral / system background, use `.primary`.

### Translucent sheets

```swift
// ❌ Default — distracting
.presentationDetents([.medium, .large])

// ✅ Solid
.presentationDetents([.medium, .large])
.presentationBackground(Color(.systemGroupedBackground))
```

Audit point: if you add a new sheet, set `.presentationBackground` explicitly. ConnectSheet was the last surface to acquire this fix during the polish session; AddAccountSheet was set during round 2.

### Cap check after the form is filled

```swift
// ❌ User fills in fields, hits Submit, sees "you're at the limit"
performAdd() // catches AccountError.accountCapReached, shows alert

// ✅ Pre-check on the entry point
private func handleAddAccountTap() {
    if appState.accounts.count >= Account.maxAccountsPerDevice {
        showCapAlert = true
        return
    }
    showSheet = true
}
```

Both layers should exist (defense-in-depth at AppState), but the pre-check is what users see.

### Transparent-PFP-without-backing

```swift
// ❌ Robohash with transparent bg shows the ring through the avatar
Image(uiImage: cachedImage).resizable().scaledToFill()

// ✅ Opaque backing keeps the silhouette distinct
ZStack {
    Color(.systemBackground)
    Image(uiImage: cachedImage).resizable().scaledToFill()
}
```

### Mutating model before writing the cache file

```swift
// ❌ SwiftUI re-renders from accounts mutation BEFORE the new image lands
self.accounts[idx] = updatedAccount  // triggers re-render
await cacheImage(from: pic, pubkey: pubkey)  // file lands AFTER re-render

// ✅ Reorder so re-renders read fresh disk
await cacheImage(from: pic, pubkey: pubkey)
self.accounts[idx] = updatedAccount
```

The mutation triggers the view re-render; the cache write should land first so the re-render reads up-to-date bytes. Pull-to-refresh worked accidentally (the `.refreshable` post-closure re-render reads disk after both complete); the AccountDetailView Refresh button had no such hook and exposed the latent bug.

### `@Binding Bool` for parent-decided routing

```swift
// ❌ Subview decides — can't intercept
struct AccountStripView: View {
    @Binding var showAddSheet: Bool
    // addPill sets showAddSheet = true directly
}

// ✅ Closure — parent decides
struct AccountStripView: View {
    let onAddTapped: () -> Void
}
```

Closure pattern lets the parent intercept (cap pre-check), without the subview knowing why.

### Inline display-name resolution

```swift
// ❌ One of nine duplicate sites pre-eb42583
private func displayLabel(for account: Account) -> String {
    if let p = account.petname, !p.isEmpty { return p }
    if let d = account.profile?.displayName, !d.isEmpty { return d }
    return String(account.pubkeyHex.prefix(8))
}

// ✅ Single source of truth
account.displayLabel
```

If you write `petname, !p.isEmpty` anywhere outside `SharedModels.swift`, you're doing it wrong.

---

## 12. References

- `Shared/AccountTheme.swift` — palette + `forAccount(pubkeyHex:)`
- `Shared/SharedModels.swift` — `Account.displayLabel`, cap constants, `AccountError`
- `Clave/Views/Home/AccountStripView.swift` — strip + pill components
- `Clave/Views/Home/SlimIdentityBar.swift` — mini-banner reference implementation
- `Clave/Views/Home/HomeView.swift` — ambient gradient, section spacing, cap pre-checks
- `Clave/Views/Settings/AccountDetailView.swift` — banner + section ordering
- `Clave/Views/Components/AvatarView.swift` — pubkey-hue placeholder
- `docs/superpowers/specs/2026-05-02-stage-c-home-redesign-design.md` — Home redesign spec (the brainstorm output that produced these patterns)
