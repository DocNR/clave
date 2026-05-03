# AccountDetailView Redesign + Pair-New-Connection Polish — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply the design system to AccountDetailView (Direction C — identity-zone banner + ambient gradient Form), extend the Profile section with `about` / `nip05` / `lud16` / paired-clients stat / Edit-on-clave.casa link, replace HomeView's Pair-New-Connection row with HIG inline action treatment.

**Architecture:** Three foundation tasks (model extension + JSON parse + helpers), four AccountDetailView tasks (visual rewrite then incremental Profile additions), one HomeView task. CachedProfile gains three optional `String` fields with no migration (Codable handles missing keys per the existing pattern at `AccountModelTests.swift:75-85`). AccountDetailView gets a full SwiftUI rewrite preserving all behavioral contracts (rename / refresh / rotate / export-current-only / delete) while adopting the design-system tokens. The Edit-on-clave.casa link constructs a fragment-prebound URL and opens via `UIApplication.shared.open(_:)`.

**Tech Stack:** SwiftUI (iOS 17+), XCTest, NostrSDK (existing). No new dependencies.

**Spec:** [`docs/superpowers/specs/2026-05-03-account-detail-view-redesign-design.md`](../specs/2026-05-03-account-detail-view-redesign-design.md)

**Branch:** `feat/multi-account` (all commits land here; rolls into v0.2.0-build45 external).

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `Shared/SharedModels.swift` | `CachedProfile` struct gains `about` / `nip05` / `lud16` optional fields | 1 |
| `ClaveTests/AccountModelTests.swift` | Round-trip + legacy-decode tests for the new fields | 1 |
| `Clave/AppState.swift` | `fetchProfile(from:pubkey:)` JSON parse extracts the new fields | 2 |
| `Shared/SharedConstants.swift` | `claveCasaEditBaseURL` constant for the outbound link | 3 |
| `Clave/AppState.swift` | `bunkerURI(for:)` per-account helper (parallel to existing single-account computed property; existing property delegates to new method) | 3 |
| `Clave/Views/Settings/AccountDetailView.swift` | Full visual rewrite then incremental Profile additions | 4–7 |
| `Clave/Views/Home/HomeView.swift` | `pairNewConnectionRow` private var → HIG inline action | 8 |

---

## Task 1: Extend CachedProfile with about / nip05 / lud16 fields

**Files:**
- Modify: `Shared/SharedModels.swift` (the `CachedProfile` struct, near line 237)
- Modify: `ClaveTests/AccountModelTests.swift` (extend the existing CachedProfile test section, after line 85)

- [ ] **Step 1: Read existing CachedProfile + AccountModelTests context**

```bash
cd /Users/danielwyler/clave/Clave
grep -n "struct CachedProfile" Shared/SharedModels.swift
grep -n "CachedProfile" ClaveTests/AccountModelTests.swift
```

Expected: One match in SharedModels showing the struct declaration; multiple matches in AccountModelTests showing the existing tests for round-trip + legacy decode (lines 62-86).

- [ ] **Step 2: Write failing tests for new fields**

Append to `ClaveTests/AccountModelTests.swift` (in the `// MARK: - CachedProfile Codable` section, after the existing `testCachedProfile_decodesPreviouslyStoredFormat` test):

```swift
    func testCachedProfile_codableRoundtrip_preservesNewFields() throws {
        let original = CachedProfile(
            displayName: "Alice",
            pictureURL: "https://example.com/a.png",
            about: "Bitcoin and signal. Long-time relay operator.",
            nip05: "alice@example.com",
            lud16: "alice@strike.me",
            fetchedAt: 1700000000.0
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CachedProfile.self, from: data)
        XCTAssertEqual(decoded.displayName, "Alice")
        XCTAssertEqual(decoded.pictureURL, "https://example.com/a.png")
        XCTAssertEqual(decoded.about, "Bitcoin and signal. Long-time relay operator.")
        XCTAssertEqual(decoded.nip05, "alice@example.com")
        XCTAssertEqual(decoded.lud16, "alice@strike.me")
        XCTAssertEqual(decoded.fetchedAt, 1700000000.0)
    }

    func testCachedProfile_decodesLegacyFormat_missingNewFields() throws {
        // Pre-2026-05-03 on-disk blob — no about / nip05 / lud16 keys.
        // Codable's optional defaulting must keep these as nil; no migration.
        let json = #"{"displayName":"Bob","pictureURL":"https://example.com/b.png","fetchedAt":1700000000.0}"#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CachedProfile.self, from: data)
        XCTAssertEqual(decoded.displayName, "Bob")
        XCTAssertEqual(decoded.pictureURL, "https://example.com/b.png")
        XCTAssertNil(decoded.about)
        XCTAssertNil(decoded.nip05)
        XCTAssertNil(decoded.lud16)
    }

    func testCachedProfile_codable_omittedNewFields_decodeAsNil() throws {
        // Verify the init defaults work as expected when callers don't pass new fields.
        let original = CachedProfile(
            displayName: "Carol",
            pictureURL: nil,
            fetchedAt: 1700000000.0
        )
        XCTAssertNil(original.about)
        XCTAssertNil(original.nip05)
        XCTAssertNil(original.lud16)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CachedProfile.self, from: data)
        XCTAssertNil(decoded.about)
        XCTAssertNil(decoded.nip05)
        XCTAssertNil(decoded.lud16)
    }

    func testCachedProfile_encodedJSON_containsNewKeysWhenSet() throws {
        // Confirm the on-disk JSON shape carries the new fields (so a future
        // reinstall recovery or external tool can read them).
        let original = CachedProfile(
            displayName: "Dave",
            pictureURL: nil,
            about: "test bio",
            nip05: "dave@example.com",
            lud16: "dave@strike.me",
            fetchedAt: 1700000000.0
        )
        let data = try JSONEncoder().encode(original)
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(jsonString.contains("\"about\""), "JSON should contain about key")
        XCTAssertTrue(jsonString.contains("\"nip05\""), "JSON should contain nip05 key")
        XCTAssertTrue(jsonString.contains("\"lud16\""), "JSON should contain lud16 key")
    }

    func testCachedProfile_equatable_recognizesNewFieldDifferences() throws {
        // Equatable conformance must distinguish profiles that differ only
        // in the new fields (so SwiftUI re-render triggers when about/
        // nip05/lud16 change without displayName/pictureURL changing).
        let base = CachedProfile(
            displayName: "Eve",
            pictureURL: "https://example.com/e.png",
            about: "first bio",
            nip05: "eve@example.com",
            lud16: "eve@strike.me",
            fetchedAt: 1700000000.0
        )
        var changedAbout = base; changedAbout.about = "second bio"
        var changedNip05 = base; changedNip05.nip05 = "eve@other.com"
        var changedLud16 = base; changedLud16.lud16 = "eve@cashapp.com"
        XCTAssertNotEqual(base, changedAbout)
        XCTAssertNotEqual(base, changedNip05)
        XCTAssertNotEqual(base, changedLud16)
        XCTAssertEqual(base, base)
    }
```

- [ ] **Step 3: Run xcodebuild to verify the test file fails to compile**

```bash
cd /Users/danielwyler/clave/Clave && xcodebuild -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' build-for-testing 2>&1 | grep -i "error:" | head -10
```

Expected: errors mentioning `Type 'CachedProfile' has no member 'about'` (or similar for `nip05`/`lud16`), and missing-argument errors on the constructor calls in `testCachedProfile_codableRoundtrip_preservesNewFields`.

- [ ] **Step 4: Extend the CachedProfile struct**

In `Shared/SharedModels.swift`, locate the `CachedProfile` struct and update it:

```swift
struct CachedProfile: Codable, Equatable {
    var displayName: String?
    var pictureURL: String?
    var about: String?
    var nip05: String?
    var lud16: String?
    var fetchedAt: Double

    init(
        displayName: String? = nil,
        pictureURL: String? = nil,
        about: String? = nil,
        nip05: String? = nil,
        lud16: String? = nil,
        fetchedAt: Double
    ) {
        self.displayName = displayName
        self.pictureURL = pictureURL
        self.about = about
        self.nip05 = nip05
        self.lud16 = lud16
        self.fetchedAt = fetchedAt
    }
}
```

The default-nil parameters preserve every existing call site that passes only `displayName` / `pictureURL` / `fetchedAt`.

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd /Users/danielwyler/clave/Clave && xcodebuild test -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:ClaveTests/AccountModelTests 2>&1 | tail -30
```

Expected: all `AccountModelTests` pass (existing + 3 new). Output ends with `Test Suite 'AccountModelTests' passed`.

- [ ] **Step 6: Run the full test suite to confirm no regressions**

```bash
cd /Users/danielwyler/clave/Clave && xcodebuild test -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **` (or equivalent — all tests pass).

- [ ] **Step 7: Commit**

```bash
cd /Users/danielwyler/clave/Clave
git add Shared/SharedModels.swift ClaveTests/AccountModelTests.swift
git -c user.name="DocNR" -c user.email="thehypoxicdrive@gmail.com" commit -m "$(cat <<'EOF'
feat(account-detail): extend CachedProfile with about/nip05/lud16

Three new optional String fields. Codable handles missing keys via Swift
default decoding for optionals — no migration needed; existing on-disk
blobs decode cleanly with the new fields as nil. Same pattern PR #19
used for ActivityEntry. AppState.fetchProfile JSON parse extension
follows in next commit; this is the model-layer foundation.

Tests (5 total, covers the spec's testing approach):
- testCachedProfile_codableRoundtrip_preservesNewFields
- testCachedProfile_decodesLegacyFormat_missingNewFields
- testCachedProfile_codable_omittedNewFields_decodeAsNil
- testCachedProfile_encodedJSON_containsNewKeysWhenSet
- testCachedProfile_equatable_recognizesNewFieldDifferences

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Extend AppState.fetchProfile JSON parse

**Files:**
- Modify: `Clave/AppState.swift` (the private `static func fetchProfile(from:pubkey:)` near line 1028, JSON parse around line 1049-1059)

- [ ] **Step 1: Read the current fetchProfile implementation**

```bash
cd /Users/danielwyler/clave/Clave && sed -n '1028,1075p' Clave/AppState.swift
```

Identify the JSON parse block (currently extracts `display_name`/`name` and `picture`) and the `CachedProfile(...)` constructor call.

- [ ] **Step 2: Extend the JSON parse and constructor call**

In `Clave/AppState.swift`, locate the lines:

```swift
let displayName = (json["display_name"] as? String) ?? (json["name"] as? String)
let pictureURL = json["picture"] as? String
```

Add three lines below them:

```swift
let about = json["about"] as? String
let nip05 = json["nip05"] as? String
let lud16 = json["lud16"] as? String
```

Then locate the `CachedProfile(...)` constructor call near line 1058 and update it:

```swift
return CachedProfile(
    displayName: displayName,
    pictureURL: pictureURL,
    about: about,
    nip05: nip05,
    lud16: lud16,
    fetchedAt: Date().timeIntervalSince1970
)
```

Keep the existing nil-or-empty bail-out (`if (displayName?.isEmpty ?? true) && (pictureURL?.isEmpty ?? true) { ... }`) unchanged — the additional fields shouldn't change the "is this kind:0 worth caching" criterion (a profile with only `about` set but no displayName/picture is unusual; safest to keep current behavior).

- [ ] **Step 3: Verify the file compiles**

```bash
cd /Users/danielwyler/clave/Clave && xcodebuild -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | grep -i "error:" | head -5
```

Expected: no compile errors (empty output or just warnings).

- [ ] **Step 4: Run the full test suite to confirm no regressions**

```bash
cd /Users/danielwyler/clave/Clave && xcodebuild test -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
cd /Users/danielwyler/clave/Clave
git add Clave/AppState.swift
git -c user.name="DocNR" -c user.email="thehypoxicdrive@gmail.com" commit -m "$(cat <<'EOF'
feat(account-detail): extract about/nip05/lud16 from kind:0 in fetchProfile

AppState.fetchProfile(from:pubkey:) now populates the three new
CachedProfile fields when present in the kind:0 JSON. All three are
optional strings per the kind:0 spec; absent → nil. Existing
displayName/pictureURL extraction unchanged. The "worth caching" gate
(displayName + pictureURL both empty → skip) is preserved — about-only
profiles still bail out, which matches existing behavior.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add SharedConstants.claveCasaEditBaseURL + AppState.bunkerURI(for:) per-account helper

The existing single-account helper `appState.bunkerURI` is a computed `String` property at `Clave/AppState.swift:178-187`. It reads `signerPubkeyHex` (current account only) + `SharedStorage.getBunkerSecret(for:)` + `SharedConstants.relayURL` and builds `"bunker://<pubkey>?relay=<encoded>&secret=<secret>"`. AccountDetailView needs a per-account variant that takes any pubkey. This task adds `func bunkerURI(for pubkey: String) -> String?` and refactors the existing computed property to delegate to it (DRY).

**Files:**
- Modify: `Shared/SharedConstants.swift`
- Modify: `Clave/AppState.swift`

- [ ] **Step 1: Read the existing bunkerURI computed property**

```bash
cd /Users/danielwyler/clave/Clave && sed -n '175,195p' Clave/AppState.swift
```

Confirm the existing implementation matches:

```swift
var bunkerURI: String {
    guard !signerPubkeyHex.isEmpty else { return "" }
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: ":/")
    let relay = SharedConstants.relayURL
        .addingPercentEncoding(withAllowedCharacters: allowed) ?? SharedConstants.relayURL
    let currentSecret = SharedStorage.getBunkerSecret(for: signerPubkeyHex)
    return "bunker://\(signerPubkeyHex)?relay=\(relay)&secret=\(currentSecret)"
}
```

- [ ] **Step 2: Add the SharedConstants entry**

In `Shared/SharedConstants.swift`, add (location: alongside other URL constants such as `relayURL`):

```swift
/// Base URL for the clave.casa kind:0 profile editor.
/// Tap target for the "Edit on clave.casa" row in AccountDetailView.
/// Construct full link as `\(claveCasaEditBaseURL)#bunker=<URL-encoded-bunker-uri>`.
/// Fragment (#) ensures the bunker URI never reaches Cloudflare logs;
/// clave.casa parses client-side and `history.replaceState`-scrubs after parse.
static let claveCasaEditBaseURL: String = "https://clave.casa/edit"
```

- [ ] **Step 3: Add the per-account `bunkerURI(for:)` method on AppState**

In `Clave/AppState.swift`, add immediately after the existing `bunkerURI` computed property (~line 187):

```swift
/// Per-account variant of `bunkerURI`. Returns the bunker URI for the
/// given signer pubkey, or nil if either the pubkey is empty or no bunker
/// secret has been initialized for that account.
///
/// Same construction as the single-account `bunkerURI` computed property,
/// which now delegates to this method.
func bunkerURI(for pubkey: String) -> String? {
    guard !pubkey.isEmpty else { return nil }
    let secret = SharedStorage.getBunkerSecret(for: pubkey)
    guard !secret.isEmpty else { return nil }
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: ":/")
    let relay = SharedConstants.relayURL
        .addingPercentEncoding(withAllowedCharacters: allowed) ?? SharedConstants.relayURL
    return "bunker://\(pubkey)?relay=\(relay)&secret=\(secret)"
}
```

- [ ] **Step 4: Refactor existing `bunkerURI` computed property to delegate (DRY)**

Replace the existing `bunkerURI` body (lines ~178-187) with:

```swift
var bunkerURI: String {
    bunkerURI(for: signerPubkeyHex) ?? ""
}
```

This preserves the existing String-not-Optional contract for callers of `appState.bunkerURI` (e.g. `ConnectShowQRView` reads it directly — that callsite stays unchanged). The per-account method returns `String?` so AccountDetailView's link construction can guard cleanly.

- [ ] **Step 5: Build + visual smoke**

```bash
cd /Users/danielwyler/clave/Clave && xcodebuild -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | grep -i "error:" | head -5
```

Expected: no compile errors. Open simulator → ConnectSheet → Show QR → confirm the bunker URI text + QR render correctly (identical to before — the format is unchanged because the construction logic is identical; only the call path differs).

- [ ] **Step 6: Run the full test suite**

```bash
cd /Users/danielwyler/clave/Clave && xcodebuild test -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
cd /Users/danielwyler/clave/Clave
git add Shared/SharedConstants.swift Clave/AppState.swift
git -c user.name="DocNR" -c user.email="thehypoxicdrive@gmail.com" commit -m "$(cat <<'EOF'
feat(account-detail): add per-account bunkerURI(for:) + clave.casa edit base URL

AppState gains func bunkerURI(for pubkey: String) -> String? — a
per-account variant of the existing single-account bunkerURI computed
property. Returns nil when the pubkey is empty or no bunker secret has
been initialized. Existing `bunkerURI` computed property now delegates
to the new method (DRY) — preserves the String-not-Optional contract
for existing callers like ConnectShowQRView.

SharedConstants.claveCasaEditBaseURL is the link target base — full URL
constructs as \(claveCasaEditBaseURL)#bunker=<URL-encoded-bunker-uri>.
Fragment-prebound design coordinates with the parallel clave.casa
session (separate items in clave-casa BACKLOG).

Used by AccountDetailView's "Edit on clave.casa" link in Task 7.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: AccountDetailView — visual rewrite (banner + ambient gradient + all sections in new style + pull-to-refresh)

This task replaces AccountDetailView with the new visual treatment **while preserving all existing content and behavior**. New Profile fields (about/nip05/lud16/stat/clave.casa link) come in Tasks 5-7.

**Files:**
- Modify: `Clave/Views/Settings/AccountDetailView.swift` (full rewrite, currently ~277 lines)

- [ ] **Step 1: Read the current AccountDetailView for behavioral contracts**

```bash
cd /Users/danielwyler/clave/Clave && wc -l Clave/Views/Settings/AccountDetailView.swift && head -100 Clave/Views/Settings/AccountDetailView.swift
```

Identify (re-confirm from spec): petname state binding, account computed property, dismiss-on-deletion, alert states, ExportKeySheet gating, deleteAlertNameSnippet/deleteAlertMessage, performRotateBunker, performDelete.

- [ ] **Step 2: Rewrite the file**

Replace the entire contents of `Clave/Views/Settings/AccountDetailView.swift` with:

```swift
import SwiftUI
import NostrSDK

/// Per-account detail screen. Reachable from:
///   • AccountStripView active-pill tap
///   • AccountStripView long-press on any pill (via pendingDetailPubkey)
///   • SettingsView Accounts section row tap
///
/// Visual direction (per docs/superpowers/specs/2026-05-03-account-detail-view-redesign-design.md):
/// identity-zone banner extends Home's per-account theme; body Form sits on
/// Home's ambient gradient with .scrollContentBackground(.hidden). Section
/// headers use sentence-case .headline + .textCase(nil) to match Home's
/// "Connected Clients" treatment.
struct AccountDetailView: View {
    let pubkeyHex: String

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var petnameInput: String = ""
    @State private var showDeleteAlert = false
    @State private var showRotateBunkerAlert = false
    @State private var showExportSheet = false

    /// The Account this view is for. Reads from appState.accounts each time
    /// so rename / delete from elsewhere update the view live. nil if account
    /// was deleted while viewing — view dismisses on appearance of nil.
    private var account: Account? {
        appState.accounts.first { $0.pubkeyHex == pubkeyHex }
    }

    /// Per-account theme. Defensive fallback to palette[0] if account is nil
    /// mid-render so the gradient never disappears.
    private var theme: AccountTheme {
        if let account {
            return AccountTheme.forAccount(pubkeyHex: account.pubkeyHex)
        }
        return AccountTheme.palette[0]
    }

    var body: some View {
        Form {
            // Banner appears as the first section's "header" so it gets
            // full-bleed treatment in Form. SwiftUI Form drops list padding
            // for clear sections we render manually.
            Section {
                EmptyView()
            } header: {
                if let account {
                    bannerHeader(for: account)
                        .listRowInsets(EdgeInsets())
                        .textCase(nil)
                }
            }
            .listRowBackground(Color.clear)

            if account != nil {
                petnameSection
                profileSection
                securitySection
                deleteSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(ambientGradient.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.3), value: appState.currentAccount?.pubkeyHex)
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            guard let pubkey = account?.pubkeyHex else { return }
            await appState.refreshProfileAsync(for: pubkey)
        }
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
    }

    // MARK: - Ambient gradient

    private var ambientGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: theme.start.opacity(0.42), location: 0.0),
                .init(color: theme.end.opacity(0.22),   location: 0.30),
                .init(color: theme.end.opacity(0.10),   location: 0.60),
                .init(color: theme.start.opacity(0.04), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Banner

    @ViewBuilder
    private func bannerHeader(for account: Account) -> some View {
        ZStack(alignment: .leading) {
            LinearGradient(
                colors: [theme.start, theme.end],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            HStack(spacing: 14) {
                avatarLarge(for: account)
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.displayLabel)
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
        let initial = String(account.displayLabel.first ?? "?").uppercased()
        return ZStack {
            if let img = cachedAvatar(for: account) {
                // Opaque backing so PFPs with transparent backgrounds (robohash,
                // some kind:0 avatars) don't bleed the banner's theme gradient
                // through the image.
                Color(.systemBackground)
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.22)
                Text(initial)
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 2))
    }

    private func cachedAvatar(for account: Account) -> UIImage? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConstants.appGroup
        ) else { return nil }
        let url = container.appendingPathComponent("cached-profile-\(account.pubkeyHex).dat")
        guard let data = try? Data(contentsOf: url),
              let img = UIImage(data: data) else { return nil }
        return img
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
        Section {
            TextField("Display label", text: $petnameInput)
                .autocorrectionDisabled()
                .listRowBackground(Color.clear)
            if let account, petnameInput.trimmingCharacters(in: .whitespacesAndNewlines) != (account.petname ?? "") {
                Button("Save Petname") {
                    let trimmed = petnameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    appState.renamePetname(for: account.pubkeyHex,
                                            to: trimmed.isEmpty ? nil : trimmed)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                .listRowBackground(Color.clear)
            }
        } header: {
            Text("Petname")
                .font(.headline)
                .foregroundStyle(.primary)
                .textCase(nil)
        }
    }

    // MARK: - Profile (placeholder — extended in Tasks 5-7)

    @ViewBuilder
    private var profileSection: some View {
        if let account {
            Section {
                if let profile = account.profile,
                   let name = profile.displayName, !name.isEmpty {
                    LabeledContent("Display name", value: name)
                        .listRowBackground(Color.clear)
                } else {
                    Text("No profile published. Pull down to refresh.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            } header: {
                Text("Profile")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }
        }
    }

    // MARK: - Security

    private var securitySection: some View {
        Section {
            if let account {
                Button {
                    showRotateBunkerAlert = true
                } label: {
                    Label("Rotate bunker secret", systemImage: "arrow.triangle.2.circlepath")
                }
                .listRowBackground(Color.clear)

                if account.pubkeyHex == appState.currentAccount?.pubkeyHex {
                    Button {
                        showExportSheet = true
                    } label: {
                        Label("Export private key", systemImage: "key.viewfinder")
                    }
                    .listRowBackground(Color.clear)
                }
            }
        } header: {
            Text("Security")
                .font(.headline)
                .foregroundStyle(.primary)
                .textCase(nil)
        }
    }

    private func performRotateBunker() {
        guard let account else { return }
        _ = SharedStorage.rotateBunkerSecret(for: account.pubkeyHex)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: - Delete

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteAlert = true
            } label: {
                Label("Delete Account", systemImage: "trash")
            }
            .listRowBackground(Color.clear)
        } footer: {
            Text("Deletes the private key from this device and unpairs all clients on this account. This cannot be undone — back up your nsec first if you may need it later.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var deleteAlertNameSnippet: String {
        guard let account else { return "this account" }
        return "@\(account.displayLabel)"
    }

    private var deleteAlertMessage: String {
        guard let account else { return "" }
        let pairs = SharedStorage.getConnectedClients(for: account.pubkeyHex).count
        let pairsClause = pairs == 0 ? "" : " and unpairs \(pairs) connection\(pairs == 1 ? "" : "s")"
        return "Permanently removes the key\(pairsClause). This cannot be undone."
    }

    private func performDelete() {
        guard let account else { return }
        appState.deleteAccount(pubkey: account.pubkeyHex)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    // MARK: - Helpers

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

**Add `refreshProfileAsync(for:)` to AppState as part of this task.** The existing `refreshProfile(for:)` at `Clave/AppState.swift:993` is non-async (fires a `Task` internally), which doesn't keep `.refreshable`'s spinner visible until the fetch completes. The private `fetchProfile(for:)` at line 914 IS already async. Add a public async wrapper that delegates to it:

```swift
// In Clave/AppState.swift, add immediately after refreshProfile(for:) (~line 996):

/// Async variant of refreshProfile(for:) for SwiftUI .refreshable callers.
/// Awaits completion so the pull-to-refresh spinner stays visible until
/// the fetch actually finishes.
@MainActor
func refreshProfileAsync(for pubkey: String) async {
    await fetchProfile(for: pubkey)
}
```

`fetchProfile(for:)` is `private` but accessible from within AppState. The new method just exposes the async path to view-layer callers.

- [ ] **Step 3: Build the project**

```bash
cd /Users/danielwyler/clave/Clave && xcodebuild -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | grep -i "error:" | head -10
```

Expected: no compile errors.

- [ ] **Step 4: Run the full test suite to confirm no behavioral regression**

```bash
cd /Users/danielwyler/clave/Clave && xcodebuild test -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Visual smoke verification in simulator**

Launch the app in the iOS Simulator. Navigate to AccountDetailView via:
1. Home → tap the active account pill (long-press if active, tap if non-active)
2. Settings → Accounts → tap a row

Verify:
- Banner: full-bleed gradient, 56pt avatar with initial or PFP, displayLabel + truncated npub on white text.
- Ambient gradient bleeds through the entire screen below the banner (rows are transparent over the gradient).
- Section headers "Petname" / "Profile" / "Security" use sentence-case bold (NOT ALL-CAPS small grey).
- Petname rename + Save: works (rename triggers list refresh).
- Profile section shows "Display name" if cached, otherwise the "No profile published. Pull down to refresh." hint.
- Pull-to-refresh: drag down on the Form, the spinner appears. (Note: if Option A was taken, the spinner dismisses immediately — that's expected.)
- Security: "Rotate bunker secret" alert names the account ("Rotate bunker secret for @<name>?"). "Export private key" only visible when current account.
- Delete: alert + footer copy correct. Confirming deletes + auto-dismisses to caller.
- Switch accounts (back to Home, switch via strip pill, drill back into a different account): banner + gradient + content all update for the new account.

- [ ] **Step 6: Commit**

```bash
cd /Users/danielwyler/clave/Clave
git add Clave/Views/Settings/AccountDetailView.swift Clave/AppState.swift
git -c user.name="DocNR" -c user.email="thehypoxicdrive@gmail.com" commit -m "$(cat <<'EOF'
feat(account-detail): visual rewrite to design-system tokens (Direction C)

Identity-zone banner extends Home's per-account theme gradient
(56pt avatar, 18/22 padding per design-doc §5.5). Body Form sits on
Home's ambient gradient via .scrollContentBackground(.hidden) +
.listRowBackground(Color.clear) per row, and the same four-stop
LinearGradient Home uses (alphas 0.42/0.22/0.10/0.04 top→bottom).

Section headers switch from default ALL-CAPS small grey to
sentence-case .headline + .textCase(nil) (matches Home's
"Connected Clients" header).

Existing behavior preserved verbatim — Petname rename, Profile
display name, Security (rotate + export gated to current), Delete
with named alert + connection-count footer. New profile fields
(about/nip05/lud16/stat/clave.casa link) come in Tasks 5-7.

Adds .refreshable {} on Form for pull-to-refresh — calls
refreshProfileAsync(for:) (added in same commit).

Spec: docs/superpowers/specs/2026-05-03-account-detail-view-redesign-design.md

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Profile section — add NIP-05, Lightning, paired-clients stat (kv-rows + stat row)

**Files:**
- Modify: `Clave/Views/Settings/AccountDetailView.swift` (the `profileSection` computed property added in Task 4)

- [ ] **Step 1: Replace the profileSection computed property**

In `Clave/Views/Settings/AccountDetailView.swift`, replace the `profileSection` defined in Task 4 with:

```swift
@ViewBuilder
private var profileSection: some View {
    if let account {
        Section {
            // Display name (kv-row, conditional on data)
            if let displayName = account.profile?.displayName, !displayName.isEmpty {
                LabeledContent("Display name", value: displayName)
                    .listRowBackground(Color.clear)
            }

            // NIP-05 (kv-row, conditional on data)
            if let nip05 = account.profile?.nip05, !nip05.isEmpty {
                LabeledContent("NIP-05", value: nip05)
                    .listRowBackground(Color.clear)
            }

            // Lightning (lud16, kv-row monospaced, conditional on data)
            if let lud16 = account.profile?.lud16, !lud16.isEmpty {
                LabeledContent("Lightning") {
                    Text(lud16)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                .listRowBackground(Color.clear)
            }

            // Paired-clients stat (always shown)
            HStack {
                Text("\(connectionCount) paired client\(connectionCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .listRowBackground(Color.clear)

            // Empty-state hint when no profile is cached at all
            if account.profile == nil ||
               (account.profile?.displayName?.isEmpty ?? true)
                && (account.profile?.nip05?.isEmpty ?? true)
                && (account.profile?.lud16?.isEmpty ?? true) {
                Text("No profile published. Pull down to refresh.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .listRowBackground(Color.clear)
            }
        } header: {
            Text("Profile")
                .font(.headline)
                .foregroundStyle(.primary)
                .textCase(nil)
        }
    }
}

private var connectionCount: Int {
    guard let account else { return 0 }
    return SharedStorage.getConnectedClients(for: account.pubkeyHex).count
}
```

(The About row + Edit-on-clave.casa row come in Tasks 6 and 7 respectively.)

- [ ] **Step 2: Build the project**

```bash
cd /Users/danielwyler/clave/Clave && xcodebuild -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | grep -i "error:" | head -5
```

Expected: no compile errors.

- [ ] **Step 3: Run the full test suite**

```bash
cd /Users/danielwyler/clave/Clave && xcodebuild test -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Visual smoke**

In simulator, navigate to AccountDetailView for an account that has profile data with `nip05` and `lud16` set (the POWR test account `npub125f8lj0pcq7xk3v68w4h9ldenhh3v3x97gumm5yl8e0mgq0dnvssjptd2l` is good). Verify:
- Display name row visible if populated.
- NIP-05 row visible if populated.
- Lightning row visible if populated, value rendered monospaced.
- "N paired clients" stat row visible (count matches Connected Clients on Home for this account).
- For an account with no profile: empty-state hint visible.

For an account without nip05/lud16: those rows hide (no row, no empty placeholder).

- [ ] **Step 5: Commit**

```bash
cd /Users/danielwyler/clave/Clave
git add Clave/Views/Settings/AccountDetailView.swift
git -c user.name="DocNR" -c user.email="thehypoxicdrive@gmail.com" commit -m "$(cat <<'EOF'
feat(account-detail): Profile section adds NIP-05 + Lightning + paired-clients stat

Three new conditional kv-rows (Display name + NIP-05 + Lightning),
each rendered only when the underlying CachedProfile field is non-empty.
"N paired clients" stat row is always shown (SharedStorage.getConnectedClients
count). Empty-state hint shows only when entire profile is empty
(no displayName / nip05 / lud16) — never shown alongside actual content.

Lightning value uses .system(.body, design: .monospaced) since lud16
addresses are technically formatted strings.

About row + Edit-on-clave.casa row come in Tasks 6 + 7.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Profile section — About block with collapse/expand

**Files:**
- Modify: `Clave/Views/Settings/AccountDetailView.swift` (extend `profileSection` from Task 5)

- [ ] **Step 1: Add `isAboutExpanded` state and `aboutOverflowsCap` heuristic**

In `Clave/Views/Settings/AccountDetailView.swift`, add to the `@State` declarations near the top of the struct:

```swift
@State private var isAboutExpanded: Bool = false
```

And add a computed helper near `connectionCount`:

```swift
/// Heuristic for "About text likely overflows two lines on iPhone".
/// True text-measurement via PreferenceKey is overkill for v0.2.0 —
/// this approximate threshold avoids the extra view-tree work.
/// Future: swap to GeometryReader-based measurement if false positives/
/// negatives become a real problem on device (BACKLOG item).
private var aboutOverflowsCap: Bool {
    (account?.profile?.about?.count ?? 0) > 80
}
```

- [ ] **Step 2: Insert the About block into `profileSection`**

In `profileSection` (Task 5 version), insert the following block **between the Display name kv-row and the NIP-05 kv-row**:

```swift
// About (stacked block, .lineLimit(2) default with tap-to-expand)
if let about = account.profile?.about, !about.isEmpty {
    VStack(alignment: .leading, spacing: 4) {
        Text("About")
            .foregroundStyle(.secondary)
            .font(.subheadline)
        Text(about)
            .foregroundStyle(.primary)
            .font(.body)
            .lineLimit(isAboutExpanded ? nil : 2)
        if aboutOverflowsCap {
            Text(isAboutExpanded ? "Show less" : "Show more")
                .foregroundStyle(theme.accent)
                .font(.caption)
                .fontWeight(.medium)
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .onTapGesture {
        guard aboutOverflowsCap else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            isAboutExpanded.toggle()
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    .listRowBackground(Color.clear)
}
```

Update the empty-state-hint condition to also account for the new field:

```swift
// Empty-state hint when no profile is cached at all
if account.profile == nil ||
   (account.profile?.displayName?.isEmpty ?? true)
    && (account.profile?.about?.isEmpty ?? true)
    && (account.profile?.nip05?.isEmpty ?? true)
    && (account.profile?.lud16?.isEmpty ?? true) {
    Text("No profile published. Pull down to refresh.")
        .font(.footnote)
        .foregroundStyle(.tertiary)
        .listRowBackground(Color.clear)
}
```

- [ ] **Step 3: Build**

```bash
cd /Users/danielwyler/clave/Clave && xcodebuild -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | grep -i "error:" | head -5
```

Expected: no compile errors.

- [ ] **Step 4: Run tests**

```bash
cd /Users/danielwyler/clave/Clave && xcodebuild test -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Visual smoke**

In simulator:
- AccountDetailView for an account with a long bio (>80 chars): About block renders 2 lines + "Show more" pill. Tap → expands to full text + "Show less". Tap again → collapses. Light haptic on toggle.
- AccountDetailView for an account with a short bio (<80 chars): About block renders without any toggle pill.
- AccountDetailView for an account with no bio: About block is hidden entirely.

To get a long-bio account quickly: edit a test account's kind:0 in clave.casa or another Nostr client, set `about` to a 200-char string, pull-to-refresh in Clave to fetch the new profile.

- [ ] **Step 6: Commit**

```bash
cd /Users/danielwyler/clave/Clave
git add Clave/Views/Settings/AccountDetailView.swift
git -c user.name="DocNR" -c user.email="thehypoxicdrive@gmail.com" commit -m "$(cat <<'EOF'
feat(account-detail): About block with tap-to-expand for long bios

About renders as a stacked block (label above, body below) instead of
kv-row treatment so multi-line bios don't break the section's vertical
rhythm. Default lineLimit(2); tap anywhere on the block toggles to full.
"Show more" / "Show less" affordance only renders when the text actually
overflows two lines (heuristic: count > 80 chars; true text-measurement
deferred to a future polish item).

Light haptic on toggle. Empty-state hint condition extended to include
about so a profile with only about set still shows actual content
rather than the placeholder.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Profile section — Edit on clave.casa link

**Files:**
- Modify: `Clave/Views/Settings/AccountDetailView.swift` (extend `profileSection` from Task 6)

- [ ] **Step 1: Add the link row to `profileSection`**

In `profileSection`, add the following **after the paired-clients stat row** (always-visible, last row in the section):

```swift
// Edit on clave.casa (always visible, outbound)
Button {
    openClaveCasaEditor()
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

- [ ] **Step 2: Add the `openClaveCasaEditor()` method**

Add to the struct, near the bottom (alongside `performDelete()` etc.):

```swift
/// Opens clave.casa's kind:0 editor with this account's bunker URI
/// pre-bound via URL fragment (never reaches a server).
/// clave.casa parses the fragment client-side and either re-uses an existing
/// pairing for this signer pubkey (skip handshake) or pairs fresh.
private func openClaveCasaEditor() {
    guard let account else { return }
    guard let bunkerURI = appState.bunkerURI(for: account.pubkeyHex) else {
        return
    }
    guard let encoded = bunkerURI.addingPercentEncoding(
        withAllowedCharacters: .urlQueryAllowed
    ) else {
        return
    }
    let urlString = "\(SharedConstants.claveCasaEditBaseURL)#bunker=\(encoded)"
    guard let url = URL(string: urlString) else { return }
    UIApplication.shared.open(url)
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
}
```

- [ ] **Step 3: Build**

```bash
cd /Users/danielwyler/clave/Clave && xcodebuild -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | grep -i "error:" | head -5
```

Expected: no compile errors.

- [ ] **Step 4: Run tests**

```bash
cd /Users/danielwyler/clave/Clave && xcodebuild test -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Visual smoke**

In simulator:
- AccountDetailView shows "Edit on clave.casa" row in Profile section, last row, with `arrow.up.right.square` outbound icon on the right.
- Tap → Safari opens with `https://clave.casa/edit#bunker=...`. Confirm the fragment is intact and the bunker URI is URL-encoded.
- If clave.casa apex is not yet deployed: Safari shows the Cloudflare error page or a 404 — that is expected behavior until the parallel clave.casa session deploys. Re-test once clave.casa is live.

Verify the URL by long-pressing in Safari → "Copy" → paste somewhere readable. Confirm shape is `https://clave.casa/edit#bunker=bunker%3A%2F%2F<pubkey>%3Frelay%3D...%26secret%3D...`.

- [ ] **Step 6: Commit**

```bash
cd /Users/danielwyler/clave/Clave
git add Clave/Views/Settings/AccountDetailView.swift
git -c user.name="DocNR" -c user.email="thehypoxicdrive@gmail.com" commit -m "$(cat <<'EOF'
feat(account-detail): Edit on clave.casa link with fragment-prebound URL

Always-visible row at the bottom of the Profile section opens
https://clave.casa/edit#bunker=<URL-encoded-bunker-uri> via
UIApplication.shared.open. Fragment never reaches a server;
clave.casa parses client-side and either re-uses an existing
pairing (matches signer pubkey in localStorage) or pairs fresh.

Coordinates with the parallel clave.casa session for /edit route +
AASA scoping (see ~/clave-casa/BACKLOG.md). Until clave.casa apex
deploys, the link reaches a 404 — acceptable for v0.2.0 since
deployment is the top item on that BACKLOG.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: HomeView pairNewConnectionRow — Option C HIG inline action

**Files:**
- Modify: `Clave/Views/Home/HomeView.swift` (the `pairNewConnectionRow` private var, lines ~321-357)

- [ ] **Step 1: Read the existing pairNewConnectionRow and supporting helpers**

```bash
cd /Users/danielwyler/clave/Clave && sed -n '315,360p' Clave/Views/Home/HomeView.swift
```

Identify: the row var, the `pairNewConnectionIcon` and `pairNewConnectionLabel` private vars (if separate), the `handlePairNewConnectionTap()` method (preserve unchanged).

- [ ] **Step 2: Replace the row implementation**

Replace `pairNewConnectionRow` (and its supporting `pairNewConnectionIcon` / `pairNewConnectionLabel` if separate) with:

```swift
private var pairNewConnectionRow: some View {
    let theme = AccountTheme.forAccount(
        pubkeyHex: appState.currentAccount?.pubkeyHex ?? ""
    )
    return Button {
        handlePairNewConnectionTap()
    } label: {
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

Delete `pairNewConnectionIcon` and `pairNewConnectionLabel` private vars if they existed (they're inlined now). Leave `handlePairNewConnectionTap()` unchanged — same cap pre-check + sheet routing as before.

- [ ] **Step 3: Build**

```bash
cd /Users/danielwyler/clave/Clave && xcodebuild -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | grep -i "error:" | head -5
```

Expected: no compile errors.

- [ ] **Step 4: Run tests**

```bash
cd /Users/danielwyler/clave/Clave && xcodebuild test -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Visual smoke**

In simulator on Home tab:
- Pair-New-Connection row at top of Connected Clients section is visually distinct from a `ConnectedClient` row at a glance: smaller leading element (22pt tinted circle vs 32pt avatar), accent-color label (vs default white), no chevron, no subtitle.
- Color of the plus + label uses the active account's `theme.accent` (verify by switching accounts via strip pill — color changes to match the new account's theme).
- Tap behavior unchanged: opens ConnectSheet (or shows the cap-reached alert if at 5 connections).
- Pair a new connection through the row → confirm the row stays at the top + new ConnectedClient row appears below.

- [ ] **Step 6: Commit**

```bash
cd /Users/danielwyler/clave/Clave
git add Clave/Views/Home/HomeView.swift
git -c user.name="DocNR" -c user.email="thehypoxicdrive@gmail.com" commit -m "$(cat <<'EOF'
feat(home): Pair New Connection row → HIG inline action treatment

Replaces the old icon-circle row (32pt theme.accent Circle + bold
subheadline + caption + chevron — visually identical to a
ConnectedClient row) with a HIG-standard inline action: 22pt tinted
plus circle + accent-color medium-weight label + no chevron + no
subtitle. Native iOS pattern (Mail "Add Mailbox", Settings
"Add Account").

Cap pre-check in handlePairNewConnectionTap() unchanged.
theme.accent threading preserved for per-account identity continuity.

Spec: docs/superpowers/specs/2026-05-03-account-detail-view-redesign-design.md

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Final verification (after all 8 tasks)

- [ ] **Full test suite passes**

```bash
cd /Users/danielwyler/clave/Clave && xcodebuild test -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`. All Stage C tests (`AccountThemeTests`, `DeeplinkRouterTests`, `LightSignerPeekMethodTests`, `NostrConnectParserTests`, `LightEventNip98Tests`, `LogExporterFormattingTests`) plus the 178 pre-sprint baseline plus 5 new `AccountModelTests` for CachedProfile fields all pass.

- [ ] **Build is clean (no warnings introduced)**

```bash
cd /Users/danielwyler/clave/Clave && xcodebuild -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | grep -iE "warning:|error:" | wc -l
```

Compare to baseline before Task 1 — should be the same warning count.

- [ ] **End-to-end behavioral verification in simulator**

Navigate to AccountDetailView via all three entry points:
1. Home → tap active account pill
2. Home → tap slim banner
3. Settings → Accounts row

Each should land on the same view, identity-styled to the active account's theme.

Exercise each behavioral contract:
- **Petname rename + Save** — list updates everywhere displayLabel is shown.
- **Pull-to-refresh** — drag down on Form, profile fetches fresh kind:0 from relays, fields update.
- **About expand/collapse** — long bio shows toggle, short doesn't, light haptic on toggle.
- **Rotate bunker secret** — named alert ("Rotate bunker secret for @<name>?") fires, accepts → secret rotates.
- **Export private key** — visible only when current account; opens ExportKeySheet.
- **Delete** — alert names the account ("Delete @<name>?"), shows connection count in message, confirming deletes + auto-dismisses.
- **Switch active account while AccountDetailView open for a different account** — re-derives `account`, banner + ambient gradient + Profile fields all update for the new active account on next view (the AccountDetailView for the previous account stays focused on the previous account; switch only affects what current is).
- **Edit on clave.casa** — Safari opens with the prebound URL (404 acceptable until clave.casa apex deploys).

On Home tab:
- **Pair New Connection row** — visually distinct from ConnectedClient rows. Tap opens ConnectSheet. Cap pre-check fires at 5 connections.

- [ ] **Diff review**

```bash
cd /Users/danielwyler/clave/Clave && git log --oneline main..HEAD | head -20
```

Expected: 8 commits on top of the pre-sprint branch tip (`60f5240`), one per Task above. Order: CachedProfile → fetchProfile → helpers → AccountDetailView visual rewrite → Profile NIP-05/Lightning/stat → About block → clave.casa link → HomeView Pair-New-Connection.

```bash
cd /Users/danielwyler/clave/Clave && git diff 60f5240..HEAD --stat
```

Sanity-check the file changes match the file table at the top of this plan: `SharedModels.swift`, `AccountModelTests.swift`, `AppState.swift`, `SharedConstants.swift`, `SharedStorage.swift`, `ConnectShowQRView.swift`, `AccountDetailView.swift`, `HomeView.swift`. No unexpected files.

---

## Sprint completion artifacts

After all 8 tasks ship cleanly:

1. The `feat/multi-account` branch carries the AccountDetailView redesign (along with all prior Stage C + ConnectSheet work).
2. `~/clave-casa/BACKLOG.md` already has the coordinating items (`/edit#bunker=` route + AASA scoping); the parallel clave.casa session can pick those up independently.
3. The next phase (Phase B in `~/.claude/plans/continuing-clave-external-rollout-sequen-iterative-bumblebee.md`) — iOS-side Universal Links wiring — depends on clave.casa AASA being deployed first. That's separate from this sprint.
4. Phase C (external rollout: URL revert + pbxproj/MARKETING_VERSION bump → archive build 45 → external promotion → tag `v0.2.0-build45`) follows once Phase A + Phase B both land.

The eight commits from this sprint do NOT yet bump pbxproj or `MARKETING_VERSION`. That single rollout commit is Phase C of the parent plan, intentionally deferred.
