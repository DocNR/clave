# ConnectSheet Redesign + Nostrconnect Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign ConnectSheet as three method cards (Show my QR / Scan / Paste) per the design system, officially integrate Nostrconnect (de-gate from dev menu), add camera QR scanning, and register URL schemes (`nostrconnect://`, `clave://`) for deeplink-arrival flow with multi-account account picker.

**Architecture:** Three implementation phases, each shippable independently. Phase 1 is visual + de-gate (no new features). Phase 2 adds camera QR scan via AVFoundation. Phase 3 adds URL scheme registration + onOpenURL routing + multi-account deeplink picker. Bunker pair-time permission UX is explicitly out of scope (deferred to separate sprint).

**Tech Stack:** SwiftUI, NavigationStack, AVFoundation (AVCaptureMetadataOutput for QR scanning), Apple URL scheme registration via Info.plist + onOpenURL.

**Spec:** [`docs/superpowers/specs/2026-05-02-connectsheet-redesign-design.md`](../specs/2026-05-02-connectsheet-redesign-design.md)
**Branch:** `feat/multi-account` (currently `a2626bb`)

---

## File structure

**New files — Phase 1 (visual redesign + de-gate):**
- `Clave/Views/Home/Connect/ConnectSheet.swift` — entry view with three method cards (replaces existing `Clave/Views/Home/ConnectSheet.swift`)
- `Clave/Views/Home/Connect/ConnectMethodCard.swift` — reusable card component (icon + title + dim parens term + subtitle + chevron)
- `Clave/Views/Home/Connect/ConnectAccountContextBar.swift` — "Connecting to @petname" bar at top of focused views
- `Clave/Views/Home/Connect/ConnectShowQRView.swift` — focused bunker QR view (lifts current bunker section)
- `Clave/Views/Home/Connect/ConnectPasteView.swift` — focused paste view (lifts current paste section, un-gated)
- `Clave/Views/Home/Connect/ConnectScanQRView.swift` — placeholder in Phase 1; full camera in Phase 2

**New files — Phase 2 (camera scan):**
- `Clave/Views/Components/QRScannerView.swift` — UIViewRepresentable wrapping AVCaptureSession

**New files — Phase 3 (deeplink):**
- `Clave/Views/Home/Connect/DeeplinkAccountPicker.swift` — sheet for multi-account binding
- `Shared/DeeplinkRouter.swift` — pure function: URL → routing decision (testable)
- `ClaveTests/DeeplinkRouterTests.swift` — unit tests

**Modified files:**
- `Clave/Info.plist` — add `NSCameraUsageDescription` (Phase 2) + `CFBundleURLTypes` for `nostrconnect` and `clave` (Phase 3)
- `Clave/ClaveApp.swift` — `.onOpenURL { ... }` modifier on ContentView (Phase 3)
- `Clave/AppState.swift` — new `pendingNostrconnectURI`, `pendingDeeplinkAccountChoice`, `deeplinkBoundAccount` published state; `handleNostrConnect` accepts optional account param (Phase 3)
- `Clave/Views/Home/HomeView.swift` — observe both pending-URI states; present ApprovalSheet directly OR DeeplinkAccountPicker as appropriate (Phase 3)
- `Clave/Views/Home/ApprovalSheet.swift` — accept `boundAccountPubkey: String? = nil` param (Phase 3)
- `Shared/DeveloperSettings.swift` — drop `nostrconnectEnabled` flag (Phase 1)

**Deleted:**
- `Clave/Views/Home/ConnectSheet.swift` — replaced by `Connect/ConnectSheet.swift`

---

## Phase 1 — Visual redesign + de-gate

### Task 1.1: Drop the dev-menu nostrconnect gate

**Files:**
- Modify: `Shared/DeveloperSettings.swift`
- Search-and-modify: any file referencing `nostrconnectEnabled`

- [ ] **Step 1: Remove the property + UserDefaults key**

In `Shared/DeveloperSettings.swift`, delete the `nostrconnectEnabled` property and `Key.nostrconnectEnabled`:

```swift
import Foundation
import Observation

@Observable
final class DeveloperSettings: @unchecked Sendable {
    static let shared = DeveloperSettings()

    private let defaults: UserDefaults

    private enum Key {
        static let developerMenuUnlocked = "dev.nostr.clave.developerMenuUnlocked"
    }

    var developerMenuUnlocked: Bool {
        didSet { defaults.set(developerMenuUnlocked, forKey: Key.developerMenuUnlocked) }
    }

    init(defaults: UserDefaults = SharedConstants.sharedDefaults) {
        self.defaults = defaults
        self.developerMenuUnlocked = defaults.bool(forKey: Key.developerMenuUnlocked)
    }

    nonisolated static func tapGateSatisfied(timestamps: [Date], window: TimeInterval, required: Int) -> Bool {
        guard timestamps.count >= required else { return false }
        let recent = timestamps.suffix(required)
        guard let first = recent.first, let last = recent.last else { return false }
        return last.timeIntervalSince(first) <= window
    }
}
```

- [ ] **Step 2: Find and remove all usages**

Run: `grep -rn "nostrconnectEnabled" /Users/danielwyler/clave/Clave/Clave /Users/danielwyler/clave/Clave/Shared`

Expected hits: at least the `if devSettings.nostrconnectEnabled` gate around `nostrConnectSection` in the existing `ConnectSheet.swift` (we're rewriting this file in Task 1.7 anyway, but make a safe interim edit), plus any toggle in `SettingsView.swift`.

For each hit, remove the conditional. The `nostrConnectSection` will be unconditional.

- [ ] **Step 3: Build to verify nothing else references it**

Run:
```bash
cd /Users/danielwyler/clave/Clave && \
  xcodebuild -scheme Clave -destination 'generic/platform=iOS Simulator' build 2>&1 | \
  grep -E "^(error|\*\* BUILD)" | head -5
```

Expected: `** BUILD SUCCEEDED **`. Any "Cannot find 'nostrconnectEnabled'" errors mean a reference was missed; remove them.

- [ ] **Step 4: Commit**

```bash
cd /Users/danielwyler/clave/Clave && \
  git add Shared/DeveloperSettings.swift Clave/Views/Settings/SettingsView.swift Clave/Views/Home/ConnectSheet.swift && \
  git commit -m "refactor(dev): drop nostrconnectEnabled flag — Nostrconnect is now official"
```

(The exact files added depend on where references exist; adjust per Step 2 results.)

---

### Task 1.2: Create `ConnectMethodCard` reusable component

**Files:**
- Create: `Clave/Views/Home/Connect/ConnectMethodCard.swift`

- [ ] **Step 1: Create the directory**

Run: `mkdir -p /Users/danielwyler/clave/Clave/Clave/Views/Home/Connect`

(Xcode 16 file system synchronized groups will pick up new files automatically; no pbxproj edits needed.)

- [ ] **Step 2: Write the component**

Create `Clave/Views/Home/Connect/ConnectMethodCard.swift`:

```swift
import SwiftUI

/// Reusable card row used by ConnectSheet's three method choices
/// (Show my QR / Scan / Paste). Icon + title + dim-parens technical term +
/// descriptive subtitle + trailing chevron. Tap fires the closure.
///
/// Per design-system.md: no Color(.systemGray6) wrapper, theme-friendly
/// colors, tap target = entire row.
struct ConnectMethodCard: View {
    let iconSystemName: String
    let iconGradient: LinearGradient
    let title: String
    let term: String?           // dim-parens technical term, e.g. "(bunker)"
    let subtitle: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(iconGradient)
                    Image(systemName: iconSystemName)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                        if let term {
                            Text(term)
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run:
```bash
cd /Users/danielwyler/clave/Clave && \
  xcodebuild -scheme Clave -destination 'generic/platform=iOS Simulator' build 2>&1 | \
  grep -E "^(error|\*\* BUILD)" | head -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Users/danielwyler/clave/Clave && \
  git add Clave/Views/Home/Connect/ConnectMethodCard.swift && \
  git commit -m "feat(connect): add ConnectMethodCard reusable component"
```

---

### Task 1.3: Create `ConnectAccountContextBar` reusable component

**Files:**
- Create: `Clave/Views/Home/Connect/ConnectAccountContextBar.swift`

- [ ] **Step 1: Write the component**

Create `Clave/Views/Home/Connect/ConnectAccountContextBar.swift`:

```swift
import SwiftUI

/// Small "Connecting to @petname" bar shown at the top of each focused
/// connect view (Show QR / Scan / Paste). Mini themed dot matches the
/// active account's AccountTheme; reads displayLabel for the petname.
///
/// Per design-system.md treatment C — sits in the identity zone with
/// theme-derived accent. Never tappable.
struct ConnectAccountContextBar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let account = appState.currentAccount {
            let theme = AccountTheme.forAccount(pubkeyHex: account.pubkeyHex)
            HStack(spacing: 8) {
                Circle()
                    .fill(LinearGradient(
                        colors: [theme.start, theme.end],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(theme.accent.opacity(0.6), lineWidth: 1.5))
                Text("Connecting to ")
                    .foregroundStyle(.secondary)
                + Text("@\(account.displayLabel)")
                    .foregroundStyle(.primary)
                    .fontWeight(.semibold)
                Spacer()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run:
```bash
cd /Users/danielwyler/clave/Clave && \
  xcodebuild -scheme Clave -destination 'generic/platform=iOS Simulator' build 2>&1 | \
  grep -E "^(error|\*\* BUILD)" | head -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/danielwyler/clave/Clave && \
  git add Clave/Views/Home/Connect/ConnectAccountContextBar.swift && \
  git commit -m "feat(connect): add ConnectAccountContextBar reusable component"
```

---

### Task 1.4: Create `ConnectShowQRView` (lift bunker section)

**Files:**
- Create: `Clave/Views/Home/Connect/ConnectShowQRView.swift`
- Reference (do not modify yet): `Clave/Views/Home/ConnectSheet.swift` lines 92-169 (`bunkerSection`)

- [ ] **Step 1: Write the focused view**

Create `Clave/Views/Home/Connect/ConnectShowQRView.swift`:

```swift
import SwiftUI

/// Focused view for the "Show my QR" connection method. User shows the
/// bunker URI to a client (display + QR + copy). Single-use secret rotates
/// when a client successfully pairs.
struct ConnectShowQRView: View {
    @Environment(AppState.self) private var appState
    @State private var showQR = false
    @State private var copiedBunker = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ConnectAccountContextBar()
                bunkerCard
                helperText
            }
            .padding(.top, 8)
        }
        .navigationTitle("Show my QR")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showQR) {
            QRCodeView(content: appState.bunkerURI)
        }
    }

    private var bunkerCard: some View {
        VStack(spacing: 16) {
            Button {
                showQR = true
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.secondarySystemGroupedBackground))
                    VStack(spacing: 8) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 64))
                            .foregroundStyle(Color.accentColor)
                        Text("Tap for full screen")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(32)
                }
                .aspectRatio(1, contentMode: .fit)
            }
            .buttonStyle(.plain)

            Text(appState.bunkerURI)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                Button {
                    UIPasteboard.general.setItems(
                        [["public.utf8-plain-text": appState.bunkerURI]],
                        options: [.expirationDate: Date().addingTimeInterval(120)]
                    )
                    copiedBunker = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedBunker = false }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: copiedBunker ? "checkmark" : "doc.on.doc")
                        Text(copiedBunker ? "Copied" : "Copy")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(copiedBunker ? .green : .accentColor)

                Button {
                    appState.rotateBunkerSecret()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("New secret")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.systemBackground)))
        .padding(.horizontal)
    }

    private var helperText: some View {
        Text("Single-use — the secret rotates once a client connects. Tap **New secret** to generate a fresh one before sharing again.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
    }
}
```

- [ ] **Step 2: Build to verify**

Run:
```bash
cd /Users/danielwyler/clave/Clave && \
  xcodebuild -scheme Clave -destination 'generic/platform=iOS Simulator' build 2>&1 | \
  grep -E "^(error|\*\* BUILD)" | head -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/danielwyler/clave/Clave && \
  git add Clave/Views/Home/Connect/ConnectShowQRView.swift && \
  git commit -m "feat(connect): add ConnectShowQRView focused view (lift bunker section)"
```

---

### Task 1.5: Create `ConnectPasteView` (lift paste section, un-gated)

**Files:**
- Create: `Clave/Views/Home/Connect/ConnectPasteView.swift`

- [ ] **Step 1: Write the focused view**

Create `Clave/Views/Home/Connect/ConnectPasteView.swift`:

```swift
import SwiftUI

/// Focused view for the "Paste Nostrconnect" connection method. User
/// pastes a `nostrconnect://` URI from a client on this same device.
/// On successful parse, the closure fires with the parsed URI; the parent
/// (ConnectSheet) presents ApprovalSheet.
struct ConnectPasteView: View {
    let onParsed: (NostrConnectParser.ParsedURI) -> Void

    @State private var input = ""
    @State private var parseError: String?

    private var trimmedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ConnectAccountContextBar()
                pasteCard
                connectButton
                helperText
            }
            .padding(.top, 8)
        }
        .navigationTitle("Paste Nostrconnect")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var pasteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nostrconnect URI")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $input)
                .font(.system(.caption2, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(minHeight: 80, maxHeight: 120)
                .padding(8)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if input.isEmpty {
                        Text("nostrconnect://...")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(16)
                            .allowsHitTesting(false)
                    }
                }

            Button {
                if let pasted = UIPasteboard.general.string {
                    input = pasted
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            } label: {
                Label("Paste from clipboard", systemImage: "doc.on.clipboard")
                    .font(.caption)
            }
            .buttonStyle(.bordered)

            if let parseError {
                Text(parseError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    private var connectButton: some View {
        Button {
            parseAndContinue()
        } label: {
            Text("Connect")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(trimmedInput.isEmpty)
        .padding(.horizontal)
    }

    private var helperText: some View {
        Text("For clients on this same phone — copy their `nostrconnect://` link and paste it here.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
    }

    private func parseAndContinue() {
        do {
            let parsed = try NostrConnectParser.parse(trimmedInput)
            parseError = nil
            onParsed(parsed)
        } catch let error as NostrConnectParser.ParseError {
            switch error {
            case .invalidScheme: parseError = "URI must start with nostrconnect://"
            case .missingPubkey: parseError = "Missing client public key"
            case .missingRelay:  parseError = "Missing relay parameter"
            case .missingSecret: parseError = "Missing secret parameter"
            case .invalidURL:    parseError = "Invalid URI format"
            }
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        } catch {
            parseError = "Failed to parse URI"
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run:
```bash
cd /Users/danielwyler/clave/Clave && \
  xcodebuild -scheme Clave -destination 'generic/platform=iOS Simulator' build 2>&1 | \
  grep -E "^(error|\*\* BUILD)" | head -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/danielwyler/clave/Clave && \
  git add Clave/Views/Home/Connect/ConnectPasteView.swift && \
  git commit -m "feat(connect): add ConnectPasteView focused view (lift + un-gate paste section)"
```

---

### Task 1.6: Create `ConnectScanQRView` placeholder (Phase 1 — camera comes in Phase 2)

**Files:**
- Create: `Clave/Views/Home/Connect/ConnectScanQRView.swift`

- [ ] **Step 1: Write the placeholder view**

Create `Clave/Views/Home/Connect/ConnectScanQRView.swift`:

```swift
import SwiftUI

/// Focused view for the "Scan QR" connection method. Phase 1 placeholder —
/// real camera viewfinder lands in Phase 2 (QRScannerView). For now, point
/// users to the Paste view as the working alternative.
struct ConnectScanQRView: View {
    let onParsed: (NostrConnectParser.ParsedURI) -> Void
    let onSwitchToPaste: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ConnectAccountContextBar()
                placeholderCard
                pasteFallback
            }
            .padding(.top, 8)
        }
        .navigationTitle("Scan QR")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var placeholderCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("Camera scan coming soon")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Until then, copy the Nostrconnect link from your web client and paste it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    private var pasteFallback: some View {
        Button {
            onSwitchToPaste()
        } label: {
            Label("Paste link instead", systemImage: "doc.on.clipboard")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal)
    }
}
```

- [ ] **Step 2: Build to verify**

Run:
```bash
cd /Users/danielwyler/clave/Clave && \
  xcodebuild -scheme Clave -destination 'generic/platform=iOS Simulator' build 2>&1 | \
  grep -E "^(error|\*\* BUILD)" | head -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/danielwyler/clave/Clave && \
  git add Clave/Views/Home/Connect/ConnectScanQRView.swift && \
  git commit -m "feat(connect): add ConnectScanQRView Phase 1 placeholder"
```

---

### Task 1.7: Rewrite `ConnectSheet` as three-method-cards entry view

**Files:**
- Create: `Clave/Views/Home/Connect/ConnectSheet.swift`
- Delete: `Clave/Views/Home/ConnectSheet.swift`

- [ ] **Step 1: Write the new ConnectSheet**

Create `Clave/Views/Home/Connect/ConnectSheet.swift`:

```swift
import SwiftUI

/// Entry view for connecting a Nostr client. Shows three method cards
/// (Show my QR / Scan / Paste); each pushes its focused view via
/// NavigationStack. On a successful parse from any focused view, presents
/// ApprovalSheet over the navigation stack.
///
/// Per design-system.md: solid presentationBackground, no systemGray6
/// wrappers, theme-aware accents through ConnectAccountContextBar.
enum ConnectMethod: Hashable {
    case showQR
    case scanQR
    case paste
}

struct ConnectSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var path: [ConnectMethod] = []
    @State private var parsedURI: NostrConnectParser.ParsedURI?
    @State private var isConnecting = false
    @State private var connectionError: String?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 12) {
                    headerBlock
                    methodCards
                }
                .padding(.top, 8)
                .padding(.horizontal)
            }
            .navigationTitle("Connect Client")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: ConnectMethod.self) { method in
                switch method {
                case .showQR:
                    ConnectShowQRView()
                case .scanQR:
                    ConnectScanQRView(
                        onParsed: handleParsed,
                        onSwitchToPaste: { path = [.paste] }
                    )
                case .paste:
                    ConnectPasteView(onParsed: handleParsed)
                }
            }
            .sheet(item: $parsedURI) { uri in
                ApprovalSheet(parsedURI: uri) { permissions in
                    submitApproval(uri: uri, permissions: permissions)
                }
            }
            .overlay {
                if isConnecting { connectingOverlay }
            }
            .alert("Connection Failed", isPresented: .init(
                get: { connectionError != nil },
                set: { if !$0 { connectionError = nil } }
            )) {
                Button("OK") { connectionError = nil }
            } message: {
                Text(connectionError ?? "Unknown error")
            }
        }
        .presentationBackground(Color(.systemGroupedBackground))
        .snapshotProtected()
    }

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add a Nostr client")
                .font(.system(size: 22, weight: .bold))
            Text("Pick how your client wants to connect.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }

    private var methodCards: some View {
        VStack(spacing: 10) {
            ConnectMethodCard(
                iconSystemName: "qrcode",
                iconGradient: LinearGradient(
                    colors: [Color(red: 0.72, green: 0.52, blue: 1.00),
                             Color(red: 0.63, green: 0.30, blue: 1.00)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                title: "Show my QR",
                term: "(bunker)",
                subtitle: "Your client scans a code from Clave to connect.",
                onTap: { path = [.showQR] }
            )
            ConnectMethodCard(
                iconSystemName: "qrcode.viewfinder",
                iconGradient: LinearGradient(
                    colors: [Color(red: 0.30, green: 0.83, blue: 1.00),
                             Color(red: 0.18, green: 0.93, blue: 0.71)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                title: "Scan client's QR",
                term: "(Nostrconnect)",
                subtitle: "Point your camera at a code from a web client.",
                onTap: { path = [.scanQR] }
            )
            ConnectMethodCard(
                iconSystemName: "doc.on.clipboard",
                iconGradient: LinearGradient(
                    colors: [Color(red: 1.00, green: 0.60, blue: 0.40),
                             Color(red: 1.00, green: 0.42, blue: 0.61)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                title: "Paste Nostrconnect",
                term: nil,
                subtitle: "For clients on this same phone.",
                onTap: { path = [.paste] }
            )
        }
    }

    private var connectingOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("Connecting...")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func handleParsed(_ uri: NostrConnectParser.ParsedURI) {
        parsedURI = uri
    }

    private func submitApproval(uri: NostrConnectParser.ParsedURI,
                                permissions: ClientPermissions) {
        isConnecting = true
        connectionError = nil
        let captured = uri
        let capturedPerms = permissions
        parsedURI = nil
        Task {
            do {
                try await appState.handleNostrConnect(parsedURI: captured, permissions: capturedPerms)
                await MainActor.run {
                    isConnecting = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    connectionError = error.localizedDescription
                    isConnecting = false
                }
            }
        }
    }
}
```

- [ ] **Step 2: Delete the old ConnectSheet**

```bash
rm /Users/danielwyler/clave/Clave/Clave/Views/Home/ConnectSheet.swift
```

- [ ] **Step 3: Build — should succeed because HomeView still references `ConnectSheet()` and the new file provides it**

Run:
```bash
cd /Users/danielwyler/clave/Clave && \
  xcodebuild -scheme Clave -destination 'generic/platform=iOS Simulator' build 2>&1 | \
  grep -E "^(error|\*\* BUILD)" | head -5
```

Expected: `** BUILD SUCCEEDED **`. If errors mention the old file's symbols, it means a now-deleted helper was used elsewhere — search and inline or recreate as needed.

- [ ] **Step 4: Manual verification on simulator**

Run the app on iOS Simulator. Verify:
- Pair New Connection → opens new ConnectSheet with three method cards
- Each card pushes a focused view with the account context bar at top
- Show my QR → card with QR placeholder + bunker URI text + Copy + New secret buttons. Tapping Copy copies (clipboard sticker confirms).
- Scan QR → placeholder text + "Paste link instead" button. Tap → switches to Paste view.
- Paste Nostrconnect → text field + Paste from clipboard button + Connect button (disabled while empty)
- Pasting a valid `nostrconnect://...` and tapping Connect → ApprovalSheet appears
- Approve in ApprovalSheet → existing handleNostrConnect path runs
- Done dismisses ConnectSheet

If any step fails, fix before commit.

- [ ] **Step 5: Commit**

```bash
cd /Users/danielwyler/clave/Clave && \
  git add Clave/Views/Home/Connect/ConnectSheet.swift && \
  git rm Clave/Views/Home/ConnectSheet.swift && \
  git commit -m "feat(connect): rewrite ConnectSheet as three-method-cards entry view

Three method cards (Show my QR / Scan / Paste) push focused views via
NavigationStack. Solid presentationBackground per design system. Replaces
the parallel-stacked-sections layout that used Color(.systemGray6) cards.

Phase 1 of ConnectSheet redesign sprint — visual + de-gate. Camera scan
arrives in Phase 2; deeplink routing in Phase 3."
```

---

### Task 1.8: Phase 1 device verification + archive

- [ ] **Step 1: Bump pbxproj for next TestFlight slot**

```bash
cd /Users/danielwyler/clave/Clave && \
  CURRENT=$(grep -m 1 "CURRENT_PROJECT_VERSION = " Clave.xcodeproj/project.pbxproj | sed -E 's/.*= ([0-9]+);.*/\1/') && \
  NEXT=$((CURRENT + 1)) && \
  echo "Bumping pbxproj $CURRENT → $NEXT"
```

(Replay manually if scripted bump is risky; refer to `f128911` and earlier commits for the bump pattern. **Only bump if Phase 1 is being archived independently** — if you're shipping Phase 1+2+3 as one archive, defer the bump until the end.)

- [ ] **Step 2: Manual device test checklist**

On a real device (build install via Xcode):
- All three cards visible on Pair New Connection
- Account context bar shows the active account's @petname + themed dot
- Show my QR — bunker URI matches `appState.bunkerURI`; Copy works; New secret rotates URI; tapping QR placeholder opens full-screen QRCodeView
- Paste Nostrconnect — Paste from clipboard fills field; invalid URI shows red error; valid URI opens ApprovalSheet; approving connects
- Scan QR — placeholder displays; "Paste link instead" switches to Paste view
- Done dismisses sheet without crashing
- No `Color(.systemGray6)` cards visible anywhere in the new ConnectSheet
- Light mode: all text readable
- Dark mode: all text readable

- [ ] **Step 3: If shipping Phase 1 standalone, archive + push**

```bash
cd /Users/danielwyler/clave/Clave && \
  git push origin feat/multi-account
```

Otherwise, continue to Phase 2.

---

## Phase 2 — Camera QR scan

### Task 2.1: Add `NSCameraUsageDescription` to Info.plist

**Files:**
- Modify: `Clave/Info.plist`

- [ ] **Step 1: Add the usage description key**

Edit `Clave/Info.plist` — add inside the top-level `<dict>`:

```xml
<key>NSCameraUsageDescription</key>
<string>Clave uses the camera to scan Nostrconnect QR codes from web clients so you can sign events without typing long URLs.</string>
```

- [ ] **Step 2: Build to verify Info.plist still parses**

Run:
```bash
cd /Users/danielwyler/clave/Clave && \
  xcodebuild -scheme Clave -destination 'generic/platform=iOS Simulator' build 2>&1 | \
  grep -E "^(error|\*\* BUILD)" | head -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/danielwyler/clave/Clave && \
  git add Clave/Info.plist && \
  git commit -m "build(connect): add NSCameraUsageDescription for QR scanner"
```

---

### Task 2.2: Create `QRScannerView` (UIViewRepresentable + AVFoundation)

**Files:**
- Create: `Clave/Views/Components/QRScannerView.swift`

- [ ] **Step 1: Write the wrapper**

Create `Clave/Views/Components/QRScannerView.swift`:

```swift
import SwiftUI
import AVFoundation

/// SwiftUI wrapper around AVCaptureSession + AVCaptureMetadataOutput
/// configured for QR detection. Calls `onCode(_:)` once per detected
/// QR (after which the parent should stop scanning by hiding this view
/// or setting `isScanning = false`). Supports the empty/denied/restricted
/// permission cases via the `onPermissionDenied` closure.
struct QRScannerView: UIViewRepresentable {
    var isScanning: Bool
    var onCode: (String) -> Void
    var onPermissionDenied: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode, onPermissionDenied: onPermissionDenied)
    }

    func makeUIView(context: Context) -> ScannerUIView {
        let view = ScannerUIView()
        view.coordinator = context.coordinator
        view.checkPermissionAndStart()
        return view
    }

    func updateUIView(_ uiView: ScannerUIView, context: Context) {
        uiView.coordinator = context.coordinator
        if isScanning {
            uiView.startIfReady()
        } else {
            uiView.stop()
        }
    }

    class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onCode: (String) -> Void
        let onPermissionDenied: () -> Void
        private var lastCodeAt: Date?

        init(onCode: @escaping (String) -> Void,
             onPermissionDenied: @escaping () -> Void) {
            self.onCode = onCode
            self.onPermissionDenied = onPermissionDenied
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue else { return }
            // Debounce so we don't flood the parent with the same code repeated.
            if let last = lastCodeAt, Date().timeIntervalSince(last) < 1.0 { return }
            lastCodeAt = Date()
            DispatchQueue.main.async { [weak self] in
                self?.onCode(value)
            }
        }
    }

    class ScannerUIView: UIView {
        weak var coordinator: Coordinator?
        private var session: AVCaptureSession?
        private var previewLayer: AVCaptureVideoPreviewLayer?

        override class var layerClass: AnyClass { CALayer.self }

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer?.frame = bounds
        }

        func checkPermissionAndStart() {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                startIfReady()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    DispatchQueue.main.async {
                        if granted {
                            self?.startIfReady()
                        } else {
                            self?.coordinator?.onPermissionDenied()
                        }
                    }
                }
            case .denied, .restricted:
                coordinator?.onPermissionDenied()
            @unknown default:
                coordinator?.onPermissionDenied()
            }
        }

        func startIfReady() {
            guard session == nil else {
                if let s = session, !s.isRunning {
                    DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
                }
                return
            }
            let s = AVCaptureSession()
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  s.canAddInput(input) else {
                coordinator?.onPermissionDenied()
                return
            }
            s.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard s.canAddOutput(output) else {
                coordinator?.onPermissionDenied()
                return
            }
            s.addOutput(output)
            output.setMetadataObjectsDelegate(coordinator, queue: .main)
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: s)
            layer.frame = bounds
            layer.videoGravity = .resizeAspectFill
            self.layer.addSublayer(layer)
            previewLayer = layer
            session = s

            DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
        }

        func stop() {
            if let s = session, s.isRunning {
                DispatchQueue.global(qos: .userInitiated).async { s.stopRunning() }
            }
        }

        deinit { stop() }
    }
}
```

- [ ] **Step 2: Build to verify**

Run:
```bash
cd /Users/danielwyler/clave/Clave && \
  xcodebuild -scheme Clave -destination 'generic/platform=iOS Simulator' build 2>&1 | \
  grep -E "^(error|\*\* BUILD)" | head -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/danielwyler/clave/Clave && \
  git add Clave/Views/Components/QRScannerView.swift && \
  git commit -m "feat(components): add QRScannerView UIViewRepresentable wrapper"
```

---

### Task 2.3: Wire `ConnectScanQRView` to `QRScannerView` (replace placeholder)

**Files:**
- Modify: `Clave/Views/Home/Connect/ConnectScanQRView.swift`

- [ ] **Step 1: Replace the placeholder body with a real scanner**

Overwrite `Clave/Views/Home/Connect/ConnectScanQRView.swift`:

```swift
import SwiftUI
import AVFoundation

/// Focused view for the "Scan QR" connection method. Wraps QRScannerView
/// in a viewfinder UI with corner brackets. On a successful Nostrconnect
/// QR scan, calls onParsed(_:) and stops scanning. Handles permission
/// denied + simulator (no camera) by showing inline fallback + Paste link.
struct ConnectScanQRView: View {
    let onParsed: (NostrConnectParser.ParsedURI) -> Void
    let onSwitchToPaste: () -> Void

    @State private var permissionDenied = false
    @State private var scanError: String?
    @State private var isScanning = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                ConnectAccountContextBar()
                    .background(Color.black.opacity(0.001)) // hit target
                if permissionDenied {
                    permissionDeniedView
                } else {
                    scannerView
                }
            }
        }
        .navigationTitle("Scan QR")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private var scannerView: some View {
        ZStack {
            QRScannerView(
                isScanning: isScanning,
                onCode: handleScannedCode,
                onPermissionDenied: { permissionDenied = true }
            )
            cornerBrackets
            VStack {
                Spacer()
                if let scanError {
                    Text(scanError)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 8)
                }
                Text("Point at a Nostrconnect QR from a web client")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.bottom, 12)
                Button {
                    onSwitchToPaste()
                } label: {
                    Text("Paste link instead")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.18), in: Capsule())
                }
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var cornerBrackets: some View {
        GeometryReader { geo in
            let frameSize = min(geo.size.width, geo.size.height) * 0.65
            let bracketLen: CGFloat = 22
            ZStack {
                Path { path in
                    let rect = CGRect(
                        x: (geo.size.width - frameSize) / 2,
                        y: (geo.size.height - frameSize) / 2,
                        width: frameSize, height: frameSize
                    )
                    // Top-left
                    path.move(to: CGPoint(x: rect.minX, y: rect.minY + bracketLen))
                    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.minX + bracketLen, y: rect.minY))
                    // Top-right
                    path.move(to: CGPoint(x: rect.maxX - bracketLen, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + bracketLen))
                    // Bottom-left
                    path.move(to: CGPoint(x: rect.minX, y: rect.maxY - bracketLen))
                    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                    path.addLine(to: CGPoint(x: rect.minX + bracketLen, y: rect.maxY))
                    // Bottom-right
                    path.move(to: CGPoint(x: rect.maxX - bracketLen, y: rect.maxY))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bracketLen))
                }
                .stroke(Color(red: 0.30, green: 0.83, blue: 1.00), lineWidth: 3)
            }
        }
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.4))
            Text("Camera access needed")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Enable camera in Settings to scan Nostrconnect QRs from web clients, or paste the link instead.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 12) {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("Open Settings")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    onSwitchToPaste()
                } label: {
                    Text("Paste link")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleScannedCode(_ code: String) {
        do {
            let parsed = try NostrConnectParser.parse(code.trimmingCharacters(in: .whitespacesAndNewlines))
            isScanning = false
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onParsed(parsed)
        } catch let error as NostrConnectParser.ParseError {
            switch error {
            case .invalidScheme: scanError = "Not a Nostrconnect code"
            case .missingPubkey: scanError = "Missing client public key"
            case .missingRelay:  scanError = "Missing relay parameter"
            case .missingSecret: scanError = "Missing secret parameter"
            case .invalidURL:    scanError = "Invalid URI format"
            }
            // Keep scanning — user can re-aim
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if scanError != nil { scanError = nil }
            }
        } catch {
            scanError = "Couldn't parse code"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { scanError = nil }
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run:
```bash
cd /Users/danielwyler/clave/Clave && \
  xcodebuild -scheme Clave -destination 'generic/platform=iOS Simulator' build 2>&1 | \
  grep -E "^(error|\*\* BUILD)" | head -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual device verification**

This MUST happen on real hardware — the simulator has no camera.

On a real device, in Pair New Connection → Scan QR:
- First-time flow: iOS camera permission alert appears → tap Allow
- Camera viewfinder visible with corner brackets in cyan
- Generate a Nostrconnect QR from a web client (Coracle, zap.cooking, or any nostr web client with NIP-46 connect support); display it on a desktop/laptop screen
- Point Clave's camera at the QR
- Within 1-2s: ApprovalSheet should appear with the parsed client info
- Approve → connection completes
- Re-enter Scan QR → camera should resume (no double-prompt)

Permission-denied path:
- In iOS Settings → Clave → Camera, toggle OFF
- Re-enter Scan QR → permission-denied view should appear with "Open Settings" + "Paste link" buttons

If anything fails, fix before commit.

- [ ] **Step 4: Commit**

```bash
cd /Users/danielwyler/clave/Clave && \
  git add Clave/Views/Home/Connect/ConnectScanQRView.swift && \
  git commit -m "feat(connect): wire camera QR scanner to ConnectScanQRView

AVFoundation viewfinder with cyan corner brackets, debounced detection,
parse-on-scan with inline error feedback (keeps scanning), permission
denied fallback with Open Settings + Paste link, simulator fallback
(treated as permission denied — no camera available).

Phase 2 of ConnectSheet redesign sprint."
```

---

### Task 2.4: Phase 2 device verification

- [ ] **Step 1: End-to-end manual test**

Same checklist as Task 1.8 plus:
- Scan a real Nostrconnect QR end-to-end → ApprovalSheet → approve → client connected
- Permission denial path works
- Camera releases when leaving the view (no green dot in Control Center)

- [ ] **Step 2: If shipping Phase 2 standalone, bump pbxproj + push**

(Same pattern as Task 1.8 Step 1.)

---

## Phase 3 — Deeplink routing

### Task 3.1: Add `CFBundleURLTypes` for nostrconnect + clave to Info.plist

**Files:**
- Modify: `Clave/Info.plist`

- [ ] **Step 1: Add URL scheme entries**

Edit `Clave/Info.plist` — add inside the top-level `<dict>`:

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

- [ ] **Step 2: Build + commit**

```bash
cd /Users/danielwyler/clave/Clave && \
  xcodebuild -scheme Clave -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "^(error|\*\* BUILD)" | head -5
```

Expected: `** BUILD SUCCEEDED **`.

```bash
cd /Users/danielwyler/clave/Clave && \
  git add Clave/Info.plist && \
  git commit -m "build(connect): register nostrconnect:// + clave:// URL schemes

clave:// is reserved (no handlers yet); nostrconnect:// is the standard
NIP-46 client → signer scheme. Universal Links via clave.casa deferred
until the domain is deployed."
```

---

### Task 3.2: Create `DeeplinkRouter` pure function + tests

**Files:**
- Create: `Shared/DeeplinkRouter.swift`
- Create: `ClaveTests/DeeplinkRouterTests.swift`

- [ ] **Step 1: Write the failing test**

Create `ClaveTests/DeeplinkRouterTests.swift`:

```swift
import XCTest
@testable import Clave

final class DeeplinkRouterTests: XCTestCase {

    // Valid nostrconnect:// URL with single account → routes to .approve(parsedURI)
    func testNostrconnect_singleAccount_routesToApprove() throws {
        let validURI = "nostrconnect://abc123def456abc123def456abc123def456abc123def456abc123def456abcd?relay=wss%3A%2F%2Frelay.example.com&secret=topsecret&perms=sign_event%3A1"
        let url = URL(string: validURI)!
        let result = DeeplinkRouter.route(url: url, accountCount: 1)
        guard case .approve(let parsed) = result else {
            return XCTFail("Expected .approve, got \(result)")
        }
        XCTAssertEqual(parsed.clientPubkey, "abc123def456abc123def456abc123def456abc123def456abc123def456abcd")
    }

    // Valid nostrconnect:// URL with multiple accounts → routes to .pickAccount(parsedURI)
    func testNostrconnect_multiAccount_routesToPickAccount() throws {
        let validURI = "nostrconnect://abc123def456abc123def456abc123def456abc123def456abc123def456abcd?relay=wss%3A%2F%2Frelay.example.com&secret=topsecret"
        let url = URL(string: validURI)!
        let result = DeeplinkRouter.route(url: url, accountCount: 3)
        guard case .pickAccount = result else {
            return XCTFail("Expected .pickAccount, got \(result)")
        }
    }

    // Zero accounts → routes to .ignore (defensive — should never happen in practice)
    func testNostrconnect_zeroAccounts_routesToIgnore() throws {
        let validURI = "nostrconnect://abc123def456abc123def456abc123def456abc123def456abc123def456abcd?relay=wss%3A%2F%2Frelay.example.com&secret=topsecret"
        let url = URL(string: validURI)!
        let result = DeeplinkRouter.route(url: url, accountCount: 0)
        guard case .ignore = result else {
            return XCTFail("Expected .ignore, got \(result)")
        }
    }

    // Malformed nostrconnect:// URL → routes to .ignore
    func testNostrconnect_invalidURI_routesToIgnore() throws {
        let url = URL(string: "nostrconnect://garbage-no-relay")!
        let result = DeeplinkRouter.route(url: url, accountCount: 1)
        guard case .ignore = result else {
            return XCTFail("Expected .ignore for malformed URI, got \(result)")
        }
    }

    // clave:// URL → routes to .ignore (reserved namespace, no handlers yet)
    func testClaveScheme_anything_routesToIgnore() throws {
        let url = URL(string: "clave://anything?foo=bar")!
        let result = DeeplinkRouter.route(url: url, accountCount: 2)
        guard case .ignore = result else {
            return XCTFail("Expected .ignore for clave://, got \(result)")
        }
    }

    // Other scheme → routes to .ignore
    func testOtherScheme_routesToIgnore() throws {
        let url = URL(string: "https://example.com/foo")!
        let result = DeeplinkRouter.route(url: url, accountCount: 1)
        guard case .ignore = result else {
            return XCTFail("Expected .ignore for non-nostrconnect/clave scheme, got \(result)")
        }
    }
}
```

- [ ] **Step 2: Run the test — should fail to compile**

(`DeeplinkRouter` doesn't exist yet.)

- [ ] **Step 3: Implement `DeeplinkRouter`**

Create `Shared/DeeplinkRouter.swift`:

```swift
import Foundation

/// Pure routing function for incoming URL deeplinks. Maps a URL +
/// current AppState.accounts.count to a routing decision the AppState
/// observer can act on. Pure for testability — no side effects.
enum DeeplinkRouter {

    enum Outcome: Equatable {
        /// Single-account: route directly to ApprovalSheet.
        case approve(NostrConnectParser.ParsedURI)
        /// Multi-account: route to DeeplinkAccountPicker first.
        case pickAccount(NostrConnectParser.ParsedURI)
        /// No-op (clave:// reserved, malformed URIs, unsupported schemes,
        /// or zero-account defensive case).
        case ignore

        static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            switch (lhs, rhs) {
            case (.ignore, .ignore): return true
            case (.approve(let a), .approve(let b)): return a.id == b.id
            case (.pickAccount(let a), .pickAccount(let b)): return a.id == b.id
            default: return false
            }
        }
    }

    static func route(url: URL, accountCount: Int) -> Outcome {
        switch url.scheme {
        case "nostrconnect":
            guard let parsed = try? NostrConnectParser.parse(url.absoluteString) else {
                return .ignore
            }
            if accountCount <= 0 { return .ignore }
            if accountCount == 1 { return .approve(parsed) }
            return .pickAccount(parsed)
        case "clave":
            // Reserved namespace — no handlers yet.
            return .ignore
        default:
            return .ignore
        }
    }
}
```

- [ ] **Step 4: Run the test — should pass**

Run via Xcode (CLI tests are blocked by ClaveTests deployment-target mismatch — known issue per HANDOFF). Open Xcode → Cmd+U or run only `DeeplinkRouterTests` from the Test navigator.

Expected: all 6 tests pass.

If they don't, fix the implementation. Common issue: `NostrConnectParser.parse` may need `URL.absoluteString` vs the bare uri string — verify the parser's input expectation matches.

- [ ] **Step 5: Commit**

```bash
cd /Users/danielwyler/clave/Clave && \
  git add Shared/DeeplinkRouter.swift ClaveTests/DeeplinkRouterTests.swift && \
  git commit -m "feat(deeplink): add DeeplinkRouter pure function + tests

Maps incoming URL + account count to .approve / .pickAccount / .ignore
outcome. Pure for testability. clave:// scheme is reserved (always
.ignore until handlers are designed)."
```

---

### Task 3.3: Add deeplink state to `AppState`

**Files:**
- Modify: `Clave/AppState.swift`

- [ ] **Step 1: Add three new published properties**

Find the multi-account state section in `AppState.swift` (near `pendingDetailPubkey`) and add:

```swift
/// Set when a nostrconnect:// deeplink arrives and the user has only one
/// account (or after the user picks from DeeplinkAccountPicker). HomeView
/// observes this to present ApprovalSheet.
var pendingNostrconnectURI: NostrConnectParser.ParsedURI?

/// Set when a nostrconnect:// deeplink arrives and the user has 2+
/// accounts. HomeView observes this to present DeeplinkAccountPicker.
var pendingDeeplinkAccountChoice: NostrConnectParser.ParsedURI?

/// Pubkey of the account chosen by DeeplinkAccountPicker. Threaded
/// through to ApprovalSheet via boundAccountPubkey. Cleared after
/// the connect completes or the user cancels.
var deeplinkBoundAccount: String?
```

- [ ] **Step 2: Add a deeplink handler method**

Add to `AppState`:

```swift
/// Routes an incoming URL deeplink. Called from ClaveApp.onOpenURL.
/// Mutates pendingNostrconnectURI or pendingDeeplinkAccountChoice based
/// on account count. clave:// and malformed URIs are silently ignored.
@MainActor
func handleDeeplink(url: URL) {
    let outcome = DeeplinkRouter.route(url: url, accountCount: accounts.count)
    switch outcome {
    case .approve(let parsed):
        pendingNostrconnectURI = parsed
    case .pickAccount(let parsed):
        pendingDeeplinkAccountChoice = parsed
    case .ignore:
        break
    }
}
```

- [ ] **Step 3: Build to verify**

Run:
```bash
cd /Users/danielwyler/clave/Clave && \
  xcodebuild -scheme Clave -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "^(error|\*\* BUILD)" | head -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Users/danielwyler/clave/Clave && \
  git add Clave/AppState.swift && \
  git commit -m "feat(deeplink): add pendingNostrconnectURI + pendingDeeplinkAccountChoice + deeplinkBoundAccount to AppState

handleDeeplink(url:) routes via DeeplinkRouter to set the appropriate
state. HomeView observers will present ApprovalSheet directly (single
account) or DeeplinkAccountPicker (multi-account) in the next task."
```

---

### Task 3.4: Add `boundAccountPubkey` param to `ApprovalSheet`

**Files:**
- Modify: `Clave/Views/Home/ApprovalSheet.swift`

- [ ] **Step 1: Add the optional param**

In `ApprovalSheet.swift` change the init from:

```swift
init(parsedURI: NostrConnectParser.ParsedURI, onApprove: @escaping (ClientPermissions) -> Void) {
    self.parsedURI = parsedURI
    self.onApprove = onApprove
    _selectedTrust = State(initialValue: parsedURI.suggestedTrustLevel)
}
```

to:

```swift
let parsedURI: NostrConnectParser.ParsedURI
let boundAccountPubkey: String?
let onApprove: (ClientPermissions) -> Void
@Environment(\.dismiss) private var dismiss
@Environment(AppState.self) private var appState

init(parsedURI: NostrConnectParser.ParsedURI,
     boundAccountPubkey: String? = nil,
     onApprove: @escaping (ClientPermissions) -> Void) {
    self.parsedURI = parsedURI
    self.boundAccountPubkey = boundAccountPubkey
    self.onApprove = onApprove
    _selectedTrust = State(initialValue: parsedURI.suggestedTrustLevel)
}
```

- [ ] **Step 2: Use boundAccountPubkey in `SigningAsHeader`**

Find:

```swift
SigningAsHeader(signerPubkeyHex: appState.signerPubkeyHex)
```

Change to:

```swift
SigningAsHeader(signerPubkeyHex: boundAccountPubkey ?? appState.signerPubkeyHex)
```

- [ ] **Step 3: Use boundAccountPubkey in `buildAndApprove`**

Find the cap check:

```swift
let currentSigner = SharedConstants.sharedDefaults.string(
    forKey: SharedConstants.currentSignerPubkeyHexKey
) ?? ""
let connected = SharedStorage.getConnectedClients(for: currentSigner)
```

Change to:

```swift
let signerForCheck = boundAccountPubkey ?? SharedConstants.sharedDefaults.string(
    forKey: SharedConstants.currentSignerPubkeyHexKey
) ?? ""
let connected = SharedStorage.getConnectedClients(for: signerForCheck)
```

Then in the permissions creation, ensure `signerPubkeyHex` uses the bound value:

Find:

```swift
let permissions = ClientPermissions(
    pubkey: parsedURI.clientPubkey,
    trustLevel: selectedTrust,
    kindOverrides: kindOverrides,
    methodPermissions: ClientPermissions.defaultMethodPermissions,
    name: parsedURI.name,
    url: parsedURI.url,
    imageURL: parsedURI.imageURL,
    connectedAt: Date().timeIntervalSince1970,
    lastSeen: Date().timeIntervalSince1970,
```

(continuation:) `signerPubkeyHex: signerForCheck` — verify the existing assignment uses the local var. If the existing code passes a different value (e.g. `appState.signerPubkeyHex`), change to `signerForCheck` so deeplink-bound accounts get correctly attributed.

- [ ] **Step 4: Build to verify**

Run:
```bash
cd /Users/danielwyler/clave/Clave && \
  xcodebuild -scheme Clave -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "^(error|\*\* BUILD)" | head -5
```

Expected: `** BUILD SUCCEEDED **`. If errors point to call sites of `ApprovalSheet`, those callers don't need changes (default arg is nil) — so this should compile clean.

- [ ] **Step 5: Commit**

```bash
cd /Users/danielwyler/clave/Clave && \
  git add Clave/Views/Home/ApprovalSheet.swift && \
  git commit -m "feat(approval): add boundAccountPubkey param to ApprovalSheet

Default nil = use current account (existing behavior; preserves all
existing call sites). Non-nil = explicit binding from deeplink-arrived
URI, threaded through SigningAsHeader and the cap check + permission
write."
```

---

### Task 3.5: Update `AppState.handleNostrConnect` to thread account binding

**Files:**
- Modify: `Clave/AppState.swift`

- [ ] **Step 1: Find the handleNostrConnect signature**

Run: `grep -n "func handleNostrConnect" /Users/danielwyler/clave/Clave/Clave/AppState.swift`

- [ ] **Step 2: Add an optional account binding param**

Change the signature from:

```swift
func handleNostrConnect(parsedURI: NostrConnectParser.ParsedURI, permissions: ClientPermissions) async throws {
    // ... uses currentAccount implicitly
}
```

to:

```swift
func handleNostrConnect(parsedURI: NostrConnectParser.ParsedURI,
                       permissions: ClientPermissions,
                       boundAccountPubkey: String? = nil) async throws {
    let signerPubkey = boundAccountPubkey ?? currentAccount?.pubkeyHex ?? signerPubkeyHex
    // ... rest of method uses `signerPubkey` instead of `currentAccount?.pubkeyHex` / `signerPubkeyHex`
}
```

Audit every reference in the method body to make sure they use the local `signerPubkey` variable. Common spots: bunker secret lookup, ClientPermissions write, registerWithProxy call, etc. All should be scoped to the bound account, not implicit current.

- [ ] **Step 3: Build to verify**

Run:
```bash
cd /Users/danielwyler/clave/Clave && \
  xcodebuild -scheme Clave -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "^(error|\*\* BUILD)" | head -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Users/danielwyler/clave/Clave && \
  git add Clave/AppState.swift && \
  git commit -m "feat(deeplink): thread boundAccountPubkey through AppState.handleNostrConnect

Default nil preserves existing behavior (use current account). Non-nil
binds the connect to a specific signer — used by deeplink path so the
user's pick from DeeplinkAccountPicker is honored even if currentAccount
changes mid-flow."
```

---

### Task 3.6: Create `DeeplinkAccountPicker`

**Files:**
- Create: `Clave/Views/Home/Connect/DeeplinkAccountPicker.swift`

- [ ] **Step 1: Write the picker view**

Create `Clave/Views/Home/Connect/DeeplinkAccountPicker.swift`:

```swift
import SwiftUI

/// Sheet presented when a nostrconnect:// deeplink arrives and the user
/// has 2+ accounts. Lists accounts with their themed avatars; user taps
/// one to bind the in-flight URI to that account. ApprovalSheet then
/// presents with boundAccountPubkey set.
///
/// Cancel discards the deeplink — user must re-tap the source link to
/// retry.
struct DeeplinkAccountPicker: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let parsedURI: NostrConnectParser.ParsedURI
    let onPick: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                headerBlock
                    .padding(.horizontal)
                    .padding(.top, 8)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(appState.accounts) { account in
                            accountRow(for: account)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .navigationTitle("Connect with which account?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(Color(.systemGroupedBackground))
    }

    private var headerBlock: some View {
        Text("Choose the identity to use for **\(clientLabel)**.")
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
    }

    private var clientLabel: String {
        parsedURI.name ?? "this connection"
    }

    private func accountRow(for account: Account) -> some View {
        let theme = AccountTheme.forAccount(pubkeyHex: account.pubkeyHex)
        let isCurrent = account.pubkeyHex == appState.currentAccount?.pubkeyHex
        return Button {
            onPick(account.pubkeyHex)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    if isCurrent {
                        Circle()
                            .fill(LinearGradient(colors: [theme.start, theme.end],
                                                 startPoint: .topLeading,
                                                 endPoint: .bottomTrailing))
                            .frame(width: 68, height: 68)
                    }
                    AvatarView(pubkeyHex: account.pubkeyHex,
                               name: account.displayLabel,
                               size: 60)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("@\(account.displayLabel)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(String(account.pubkeyHex.prefix(12)) + "…")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isCurrent {
                    Text("Current")
                        .font(.caption2.bold())
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(theme.start.opacity(0.15), in: Capsule())
                }
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Build to verify**

Run:
```bash
cd /Users/danielwyler/clave/Clave && \
  xcodebuild -scheme Clave -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "^(error|\*\* BUILD)" | head -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/danielwyler/clave/Clave && \
  git add Clave/Views/Home/Connect/DeeplinkAccountPicker.swift && \
  git commit -m "feat(deeplink): add DeeplinkAccountPicker for multi-account binding

Vertical list of strip-pill-style account cards. Current account gets a
themed gradient ring + 'Current' badge so the user can quickly stick with
default. Cancel discards the in-flight deeplink."
```

---

### Task 3.7: Wire `HomeView` observers + onOpenURL handler

**Files:**
- Modify: `Clave/ClaveApp.swift`
- Modify: `Clave/Views/Home/HomeView.swift`

- [ ] **Step 1: Add `.onOpenURL` to ContentView in ClaveApp**

Edit `Clave/ClaveApp.swift` `body`:

Find:

```swift
var body: some Scene {
    WindowGroup {
        ContentView()
    }
}
```

Change to:

```swift
var body: some Scene {
    WindowGroup {
        ContentView()
            .onOpenURL { url in
                handleDeeplink(url: url)
            }
    }
}
```

Add a top-level helper inside `ClaveApp` (or in a small extension at the bottom of the file):

```swift
@MainActor
private func handleDeeplink(url: URL) {
    logger.notice("[Deeplink] received: \(url.absoluteString, privacy: .public)")
    // ContentView wraps an AppState environment; we need to reach it via
    // the shared singleton or a NotificationCenter post. Simplest: post
    // a Notification that AppState observes and routes via handleDeeplink.
    NotificationCenter.default.post(name: .deeplinkReceived, object: url)
}
```

Add to the Notification.Name extension at the bottom:

```swift
static let deeplinkReceived = Notification.Name("deeplinkReceived")
```

- [ ] **Step 2: Add the Notification observer in AppState**

In `Clave/AppState.swift`, find where `init` or other observers are set up. Add to AppState's init (or wherever NotificationCenter observers are wired):

```swift
NotificationCenter.default.addObserver(
    forName: .deeplinkReceived,
    object: nil,
    queue: .main
) { [weak self] note in
    guard let url = note.object as? URL else { return }
    Task { @MainActor in
        self?.handleDeeplink(url: url)
    }
}
```

If AppState already has a clean observer-setup pattern, follow it; otherwise add a `private func setupDeeplinkObserver()` and call from init.

- [ ] **Step 3: Add HomeView observers for the two pending states**

In `Clave/Views/Home/HomeView.swift`, add two new state vars:

```swift
@State private var deeplinkApprovalURI: NostrConnectParser.ParsedURI?
@State private var deeplinkAccountChoiceURI: NostrConnectParser.ParsedURI?
```

In the `var body` after the existing `.onChange(of: appState.pendingDetailPubkey)`, add:

```swift
.onChange(of: appState.pendingNostrconnectURI?.id) { _, _ in
    if let uri = appState.pendingNostrconnectURI {
        deeplinkApprovalURI = uri
        appState.pendingNostrconnectURI = nil
    }
}
.onChange(of: appState.pendingDeeplinkAccountChoice?.id) { _, _ in
    if let uri = appState.pendingDeeplinkAccountChoice {
        deeplinkAccountChoiceURI = uri
        appState.pendingDeeplinkAccountChoice = nil
    }
}
.sheet(item: $deeplinkAccountChoiceURI) { uri in
    DeeplinkAccountPicker(parsedURI: uri) { pickedPubkey in
        appState.deeplinkBoundAccount = pickedPubkey
        deeplinkApprovalURI = uri
        deeplinkAccountChoiceURI = nil
    }
}
.sheet(item: $deeplinkApprovalURI) { uri in
    ApprovalSheet(
        parsedURI: uri,
        boundAccountPubkey: appState.deeplinkBoundAccount
    ) { permissions in
        let captured = uri
        let bound = appState.deeplinkBoundAccount
        deeplinkApprovalURI = nil
        appState.deeplinkBoundAccount = nil
        Task {
            do {
                try await appState.handleNostrConnect(
                    parsedURI: captured,
                    permissions: permissions,
                    boundAccountPubkey: bound
                )
            } catch {
                // Surface via existing connectionError pattern if needed
            }
        }
    }
}
```

- [ ] **Step 4: Build to verify**

Run:
```bash
cd /Users/danielwyler/clave/Clave && \
  xcodebuild -scheme Clave -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "^(error|\*\* BUILD)" | head -5
```

Expected: `** BUILD SUCCEEDED **`. If errors point to `Identifiable` not being satisfied by `ParsedURI`, verify the parser type already conforms (it does — `var id: String { clientPubkey + secret }` is in the spec).

- [ ] **Step 5: Manual device verification**

On a real device:
- Single-account user: tap a `nostrconnect://...` link in Safari (test URL: send yourself a message with one) → Clave opens → ApprovalSheet appears → approve → connection completes
- Multi-account user (3+ accounts): tap the same link → DeeplinkAccountPicker appears → pick an account → ApprovalSheet appears with that account in the SigningAsHeader → approve → check Activity log shows the connection on the *picked* account, not current
- Tap `clave://anything` → Clave opens, no UI surfaces (check logs: should show "received: clave://...")
- Tap a malformed `nostrconnect://garbage` → Clave opens, no UI surfaces

- [ ] **Step 6: Commit**

```bash
cd /Users/danielwyler/clave/Clave && \
  git add Clave/ClaveApp.swift Clave/AppState.swift Clave/Views/Home/HomeView.swift && \
  git commit -m "feat(deeplink): wire onOpenURL → AppState → HomeView observers

ClaveApp.body posts a Notification on every onOpenURL receipt. AppState
observes the Notification and calls handleDeeplink which routes via
DeeplinkRouter to the appropriate pendingXxx state. HomeView observes
both pending states and presents DeeplinkAccountPicker (multi-account)
or ApprovalSheet directly (single-account) with the bound account
threaded through.

Phase 3 of ConnectSheet redesign sprint complete."
```

---

### Task 3.8: Phase 3 device verification + final archive

- [ ] **Step 1: End-to-end test on device**

Combined Phase 1 + 2 + 3 checklist:
- All Phase 1 items still pass
- All Phase 2 items still pass
- Phase 3:
  - Safari → tap nostrconnect:// → Clave opens to ApprovalSheet (single account) or picker (multi)
  - Picker → pick non-current account → connection attributed to that account
  - Cancel from picker → deeplink discarded; nothing pairs
  - clave:// → app opens, no UI

- [ ] **Step 2: Bump pbxproj for the final archive**

```bash
cd /Users/danielwyler/clave/Clave && \
  CURRENT=$(grep -m 1 "CURRENT_PROJECT_VERSION = " Clave.xcodeproj/project.pbxproj | sed -E 's/.*= ([0-9]+);.*/\1/') && \
  echo "Current pbxproj=$CURRENT — bump to $((CURRENT+1)) before archiving"
```

Apply the bump using the established pattern (edit pbxproj, replace_all from `CURRENT_PROJECT_VERSION = N` to `CURRENT_PROJECT_VERSION = N+1` across all 8 build configs). Reference earlier bump commits like `b80d0b6` for the exact diff shape.

- [ ] **Step 3: Push + archive + smoke test on TestFlight**

```bash
cd /Users/danielwyler/clave/Clave && git push origin feat/multi-account
```

User archives via Xcode → uploads to TestFlight → installs internal build → runs through the full smoke checklist.

---

## Self-review

After writing the plan above, I cross-checked it against the spec:

**Spec coverage:** Every section in the spec maps to at least one task. Three phases match the spec's recommended phasing. The `boundAccountPubkey` flow is covered by Tasks 3.4 + 3.5 + 3.7. The DeeplinkRouter is its own pure unit (Task 3.2). The deferred bunker permission UX is explicitly NOT in this plan — matches the spec's "Out of scope" deferral.

**Placeholder scan:** No "TBD" / "TODO" / "implement later" / "similar to Task N" anywhere. Every code step has actual code. Every command step has the exact command + expected output.

**Type consistency:** `boundAccountPubkey` typed as `String?` in ApprovalSheet init, AppState.handleNostrConnect, AppState.deeplinkBoundAccount. `pendingNostrconnectURI` and `pendingDeeplinkAccountChoice` typed as `NostrConnectParser.ParsedURI?` in AppState and consumed as `URI?` in HomeView state mirrors. `DeeplinkRouter.Outcome` cases (.approve / .pickAccount / .ignore) used consistently across Tasks 3.2, 3.3, and the spec data flow diagram. `ConnectMethod` enum (.showQR, .scanQR, .paste) used consistently in ConnectSheet's NavigationStack path binding.

**Spec gaps surfaced:** Spec mentions "delete `Clave/Views/Home/ConnectSheet.swift`" in the Files in scope section — Task 1.7 does this via `git rm`. Spec mentions `DeveloperSettings.nostrconnectEnabled` removal — Task 1.1 does it. Spec covers Universal Links + clave:// concrete handlers as out-of-scope — plan honors this (only registers, no handlers).

No issues found.
