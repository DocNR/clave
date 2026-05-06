# ConnectSheet Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace ConnectSheet's 3-card method chooser with a single sheet whose body switches between a Bunker tab and a Nostrconnect tab via a segmented control. Bundles a small drive-by visibility + tint fix on HomeView's empty-state "Connect a Client" CTA.

**Architecture:** One `ConnectSheet` view hosts a `Picker(selection:)` segmented control + a tab-body switch. Three new view files isolate each tab body's responsibility (`ConnectBunkerTabView`, `ConnectNostrconnectTabView`, `ConnectHelpSheet`). The existing camera scanner logic from `ConnectScanQRView` gets refactored into a child component used inside the Nostrconnect tab. Four obsolete files (`ConnectMethodCard`, `ConnectShowQRView`, `ConnectScanQRView`, `ConnectPasteView`) get deleted; the project uses Xcode synchronized folders so no pbxproj surgery is required.

**Tech Stack:** SwiftUI 5 (Svelte runes-style state via `@State`), `AVFoundation` for camera, `CoreImage.CIFilterBuiltins` for QR generation, existing `NostrConnectParser` for paste validation.

**Spec:** `docs/superpowers/specs/2026-05-04-connect-sheet-redesign-design.md` (commit `e6bcd8e`).

---

## Pre-flight

This plan was authored on `docs/connect-sheet-redesign` branch (off main `1674c34`). The repo currently has uncommitted parallel WIP from the approve-pending UX redesign sprint (per HANDOFF.md). The HomeView icon + tint changes covered in Task 7 are **already in the working tree** as part of the brainstorm session.

**Recommended branch sequencing before starting Task 1:**

1. Decide whether the parallel approve-pending sprint commits first OR this redesign commits first. They touch overlapping files (`Clave/Views/Home/HomeView.swift`, `Clave/Views/Home/PendingApprovalsView.swift`, `Shared/PendingApprovalBanner.swift`) — they should NOT be in the same PR.
2. If approve-pending lands first: rebase this branch on top once it merges to main.
3. If this redesign lands first: ensure the approve-pending sprint rebases cleanly afterward.

The HomeView changes are isolated to `emptyClientsView` (lines 366-398). The approve-pending WIP has not touched `emptyClientsView` (verified via `git diff` during brainstorm). Sequencing is purely about tidy commit hygiene, not about merge conflicts.

---

## File map

**Created:**
- `Clave/Views/Home/Connect/ConnectHelpSheet.swift` — explanatory sheet for "What's a nostrconnect URI?"
- `Clave/Views/Home/Connect/ConnectBunkerTabView.swift` — Bunker tab body (QR + tap-to-copy URI section + Copy/New-secret action row)
- `Clave/Views/Home/Connect/ConnectNostrconnectTabView.swift` — Nostrconnect tab body (camera + paste field + help link)

**Rewritten:**
- `Clave/Views/Home/Connect/ConnectSheet.swift` — container for segmented control + tab body switch. Drops `ConnectMethod` enum, `path: [ConnectMethod]` state, `methodCards`, `headerBlock`, and `navigationDestination(for: ConnectMethod.self)`.

**Modified (already in working tree from brainstorm):**
- `Clave/Views/Home/HomeView.swift:366-398` — `emptyClientsView`: icon swap (`plus.circle.fill` → `plus`) + `.tint(theme.accent)`. Verified during Task 7.

**Deleted:**
- `Clave/Views/Home/Connect/ConnectMethodCard.swift`
- `Clave/Views/Home/Connect/ConnectShowQRView.swift` (content absorbed into `ConnectBunkerTabView`)
- `Clave/Views/Home/Connect/ConnectScanQRView.swift` (camera logic absorbed into `ConnectNostrconnectTabView`)
- `Clave/Views/Home/Connect/ConnectPasteView.swift` (paste field inlined in `ConnectNostrconnectTabView`)

**Unchanged:**
- `Clave/Views/Home/Connect/ConnectAccountContextBar.swift` — still rendered above the tab body
- `Clave/Views/Home/Connect/DeeplinkAccountPicker.swift` — separate flow via `DeeplinkRouter`
- `Shared/NostrConnectParser.swift`
- `Clave/AppState.swift` (`bunkerURI`, `rotateBunkerSecret`, `handleNostrConnect` — all referenced unchanged)

---

## Task 1 — ConnectHelpSheet.swift (the explanatory sheet)

Simplest task; pure presentation, no state machine, no I/O. Doing this first establishes the help-link target referenced by Task 3.

**Files:**
- Create: `Clave/Views/Home/Connect/ConnectHelpSheet.swift`

- [ ] **Step 1: Write the file.**

```swift
import SwiftUI

/// Static explanatory sheet shown when the user taps the
/// "What's a nostrconnect URI?" help link on the Nostrconnect tab.
/// Uses presentationDetents([.medium]) so it covers the bottom half
/// of the screen without dismissing the parent ConnectSheet.
///
/// Copy intentionally avoids jargon beyond `nostrconnect://` itself —
/// that's the literal string users need to recognize. Includes a
/// "what happens next" so users know pasting doesn't auto-commit.
struct ConnectHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Some Nostr web apps and clients let you sign in with a remote signer like Clave. When you choose \"Connect a remote signer,\" they show you a code that starts with `nostrconnect://`.")
                        .font(.body)
                    Text("**Bring that code here:** scan the QR with the camera, or copy the URI and paste it into the field below.")
                        .font(.body)
                    Text("The URI tells Clave which client wants to connect, where to reach it, and which encryption keys to use. After you paste it, Clave will ask you to approve the connection — including which kinds of events the client can sign.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .navigationTitle("What's a nostrconnect URI?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    Text("Tap to show")
        .sheet(isPresented: .constant(true)) {
            ConnectHelpSheet()
        }
}
```

- [ ] **Step 2: Build the project to confirm the file compiles.**

Run: `xcodebuild -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`

If it fails: read the compiler error, fix the syntax, re-run.

- [ ] **Step 3: Commit.**

```bash
cd ~/clave/Clave
git add Clave/Views/Home/Connect/ConnectHelpSheet.swift
git commit -m "feat(connect): add ConnectHelpSheet for nostrconnect URI explanation"
```

---

## Task 2 — ConnectBunkerTabView.swift (Bunker tab body)

Carries forward the existing `ConnectShowQRView` logic with two enhancements: (a) a labeled "Bunker URI" header above the URI text, (b) the URI text card itself becomes tap-to-copy (whole card, not just the QR or the Copy button).

**Files:**
- Create: `Clave/Views/Home/Connect/ConnectBunkerTabView.swift`

- [ ] **Step 1: Write the file.**

```swift
import SwiftUI
import CoreImage.CIFilterBuiltins

/// Body of the "Bunker" tab in ConnectSheet. Renders the user's current
/// bunker URI as both a QR code and a labeled text section, with three
/// tap-to-copy affordances (QR, URI text card, Copy button) and a
/// "New secret" rotate action.
///
/// Replaces the previous ConnectShowQRView. Differences:
/// - URI text now has a "Bunker URI" header label so users don't mistake
///   it for caption-text below the QR (Brian's discoverability bug).
/// - URI text card is itself tap-to-copy, not just the dedicated button.
/// - Helper text "Single-use — secret rotates" removed (auto-rotation
///   already covers this; the helper was educating about a behavior
///   users don't actively manage).
struct ConnectBunkerTabView: View {
    @Environment(AppState.self) private var appState
    @State private var showQR = false
    @State private var copiedBunker = false

    /// QR generator — same CIFilter pipeline ConnectShowQRView used.
    private func qrImage(for content: String) -> Image {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage,
              let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else {
            return Image(systemName: "xmark.circle")
        }
        return Image(uiImage: UIImage(cgImage: cgImage))
    }

    private func copyBunkerURI() {
        UIPasteboard.general.setItems(
            [["public.utf8-plain-text": appState.bunkerURI]],
            options: [.expirationDate: Date().addingTimeInterval(120)]
        )
        copiedBunker = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedBunker = false }
    }

    var body: some View {
        if appState.bunkerURI.isEmpty {
            // Empty bunker URI — no signer key imported yet. Shouldn't be
            // reachable from the user-facing flow but guard anyway.
            VStack(spacing: 12) {
                Image(systemName: "key.slash")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("No signer key imported yet")
                    .font(.headline)
                Text("Add an account in Settings to generate a bunker URI.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        } else {
            ScrollView {
                VStack(spacing: 16) {
                    qrCard
                    uriCard
                    actionRow
                }
                .padding(.top, 12)
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .sheet(isPresented: $showQR) {
                QRCodeView(content: appState.bunkerURI)
            }
        }
    }

    private var qrCard: some View {
        VStack(spacing: 8) {
            Button {
                showQR = true
            } label: {
                qrImage(for: appState.bunkerURI)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: 240)
            }
            .buttonStyle(.plain)
            Text("Tap QR or **Copy** to share this bunker URI")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var uriCard: some View {
        Button {
            copyBunkerURI()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Bunker URI")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(appState.bunkerURI)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                copyBunkerURI()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: copiedBunker ? "checkmark" : "doc.on.doc")
                    Text(copiedBunker ? "Copied" : "Copy URI")
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
}
```

- [ ] **Step 2: Build to confirm it compiles.**

Run: `xcodebuild -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`

If it fails: read the compiler error. The most likely failure is `appState.bunkerURI` or `rotateBunkerSecret` API drift — confirm against `Clave/AppState.swift`.

- [ ] **Step 3: Commit.**

```bash
cd ~/clave/Clave
git add Clave/Views/Home/Connect/ConnectBunkerTabView.swift
git commit -m "feat(connect): add ConnectBunkerTabView with labeled URI + tap-to-copy card"
```

---

## Task 3 — ConnectNostrconnectTabView.swift (Nostrconnect tab body)

Composes the existing camera scanner logic with a paste field and the help link. The camera permission denial path renders an inline "Open Settings" placeholder while keeping the paste field functional.

This task pulls QR-detection logic OUT of the existing `ConnectScanQRView` and into a private `CameraScanner` SwiftUI view inside `ConnectNostrconnectTabView.swift` (or a sibling helper file if more than ~100 lines). The existing `ConnectScanQRView` gets deleted in Task 5 once this replacement is in place.

**Files:**
- Create: `Clave/Views/Home/Connect/ConnectNostrconnectTabView.swift`
- Read for reference: `Clave/Views/Home/Connect/ConnectScanQRView.swift` — to understand the existing AVFoundation setup (camera session, QR detection delegate, frame layout).

- [ ] **Step 1: Read the existing ConnectScanQRView for reference.**

Run: `cat ~/clave/Clave/Clave/Views/Home/Connect/ConnectScanQRView.swift | head -200`
Note: Capture the AVCaptureSession setup, the QR-detection delegate that calls `onParsed` after successful `NostrConnectParser.parse`, and the camera-permission-state handling. Reuse these patterns; do not invent new ones.

- [ ] **Step 2: Write the file.**

```swift
import SwiftUI
import AVFoundation

/// Body of the "Nostrconnect" tab in ConnectSheet. Composes a live camera
/// viewfinder + a paste field + a help link. The camera permission denial
/// path renders an inline placeholder with an "Open Settings" link;
/// the paste field stays functional regardless of camera state.
///
/// Replaces both ConnectScanQRView and ConnectPasteView from the old
/// 3-card flow. The user no longer has to choose between scan and paste —
/// both inputs are visible on the same screen.
struct ConnectNostrconnectTabView: View {
    let onParsed: (NostrConnectParser.ParsedURI) -> Void

    @State private var pasteText = ""
    @State private var pasteError: String?
    @State private var showHelp = false
    @State private var cameraAuthState: AVAuthorizationStatus = .notDetermined

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                cameraSection
                pasteSection
                helpLink
            }
            .padding(.top, 12)
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .onAppear {
            cameraAuthState = AVCaptureDevice.authorizationStatus(for: .video)
            if cameraAuthState == .notDetermined {
                Task {
                    let granted = await AVCaptureDevice.requestAccess(for: .video)
                    await MainActor.run {
                        cameraAuthState = granted ? .authorized : .denied
                    }
                }
            }
        }
        .sheet(isPresented: $showHelp) {
            ConnectHelpSheet()
        }
    }

    @ViewBuilder
    private var cameraSection: some View {
        switch cameraAuthState {
        case .authorized:
            CameraScannerView(onParsed: onParsed)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        case .denied, .restricted:
            cameraDeniedPlaceholder
        case .notDetermined:
            cameraRequestingPlaceholder
        @unknown default:
            cameraDeniedPlaceholder
        }
    }

    private var cameraDeniedPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Camera access denied")
                .font(.headline)
                .foregroundStyle(.secondary)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var cameraRequestingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Requesting camera access…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var pasteSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Or paste a URI")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            TextField("nostrconnect://...", text: $pasteText)
                .font(.system(.caption, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.URL)
                .submitLabel(.go)
                .padding(10)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(pasteError == nil ? Color.clear : Color.red, lineWidth: 1)
                )
                .onSubmit { validateAndSubmit() }
                .onChange(of: pasteText) { _, _ in
                    // Clear error when user types so the red border doesn't
                    // linger after they start fixing the URI.
                    if pasteError != nil { pasteError = nil }
                }
            if let pasteError {
                Text(pasteError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private var helpLink: some View {
        Button {
            showHelp = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text("What's a nostrconnect URI?")
            }
            .font(.subheadline)
            .fontWeight(.medium)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .padding(.top, 4)
    }

    private func validateAndSubmit() {
        let trimmed = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let parsed = try NostrConnectParser.parse(trimmed)
            pasteError = nil
            onParsed(parsed)
        } catch {
            pasteError = "That doesn't look like a valid nostrconnect URI."
        }
    }
}

/// Camera scanner extracted from the legacy ConnectScanQRView. Wraps an
/// AVFoundation capture session + AVCaptureMetadataOutput for QR codes.
/// Calls onParsed exactly once when a valid nostrconnect:// URI is detected.
struct CameraScannerView: UIViewRepresentable {
    let onParsed: (NostrConnectParser.ParsedURI) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onParsed: onParsed)
    }

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.coordinator = context.coordinator
        view.startSession()
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onParsed: (NostrConnectParser.ParsedURI) -> Void
        private var consumed = false

        init(onParsed: @escaping (NostrConnectParser.ParsedURI) -> Void) {
            self.onParsed = onParsed
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !consumed,
                  let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let raw = object.stringValue else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = try? NostrConnectParser.parse(trimmed) {
                consumed = true
                DispatchQueue.main.async { self.onParsed(parsed) }
            }
        }
    }
}

/// AVFoundation capture session + preview layer wrapper. Owns the session
/// lifecycle so it gets cleaned up when the view tears down.
final class CameraPreviewView: UIView {
    weak var coordinator: CameraScannerView.Coordinator?
    private var session: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    func startSession() {
        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let metadataOutput = AVCaptureMetadataOutput()
        guard session.canAddOutput(metadataOutput) else { return }
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(coordinator, queue: .main)
        metadataOutput.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = bounds
        layer.addSublayer(preview)
        self.previewLayer = preview
        self.session = session

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }

    deinit {
        session?.stopRunning()
    }
}
```

- [ ] **Step 3: Build.**

Run: `xcodebuild -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`

If it fails: most likely candidates are `NostrConnectParser.parse` API drift (verify in `Shared/NostrConnectParser.swift`) or AVFoundation API changes. The `CameraScannerView` is intentionally a near-copy of the existing `ConnectScanQRView` to minimize regression risk.

- [ ] **Step 4: Commit.**

```bash
cd ~/clave/Clave
git add Clave/Views/Home/Connect/ConnectNostrconnectTabView.swift
git commit -m "feat(connect): add ConnectNostrconnectTabView (camera + paste + help)"
```

---

## Task 4 — Rewrite ConnectSheet.swift (segmented control + tab body switch)

This is where the structural change lands. Drops the `ConnectMethod` enum, `path: [ConnectMethod]` state, `headerBlock`, `methodCards`, and `navigationDestination`. Adds a `Tab` enum + `selectedTab: Tab` state + a `Picker` + a tab-body switch.

**Files:**
- Modify: `Clave/Views/Home/Connect/ConnectSheet.swift` (full rewrite)

- [ ] **Step 1: Replace the file contents.**

```swift
import SwiftUI

/// Entry view for connecting a Nostr client. One sheet; segmented control
/// switches between Bunker (Clave shows a code to a client) and Nostrconnect
/// (a client shows a code to Clave). On a successful parse from either tab,
/// presents ApprovalSheet over the navigation stack.
///
/// Per design-system.md: solid presentationBackground, no systemGray6
/// wrappers, theme-aware accents through ConnectAccountContextBar.
///
/// Replaces the previous 3-card method chooser. See
/// docs/superpowers/specs/2026-05-04-connect-sheet-redesign-design.md.
struct ConnectSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private enum Tab: Hashable { case bunker, nostrconnect }

    @State private var selectedTab: Tab = .bunker
    @State private var parsedURI: NostrConnectParser.ParsedURI?
    @State private var isConnecting = false
    @State private var connectionError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    Text("Bunker").tag(Tab.bunker)
                    Text("Nostrconnect").tag(Tab.nostrconnect)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)

                ConnectAccountContextBar()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                tabBody
            }
            .navigationTitle("Connect Client")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
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

    @ViewBuilder
    private var tabBody: some View {
        switch selectedTab {
        case .bunker:
            ConnectBunkerTabView()
        case .nostrconnect:
            ConnectNostrconnectTabView(onParsed: handleParsed)
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

- [ ] **Step 2: Build.**

Run: `xcodebuild -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`

If it fails: at this point the build should fail because `ConnectMethodCard`, `ConnectShowQRView`, `ConnectScanQRView`, `ConnectPasteView` are no longer referenced from anywhere — but the files still exist. SwiftPM/Xcode will compile them. Compiler errors should be inside ConnectSheet.swift only. Most likely candidates: a stale `ConnectMethod` reference somewhere I missed (search the file). Fix the syntax, re-run.

- [ ] **Step 3: Commit.**

```bash
cd ~/clave/Clave
git add Clave/Views/Home/Connect/ConnectSheet.swift
git commit -m "refactor(connect): rewrite ConnectSheet with segmented control over tab bodies"
```

---

## Task 5 — Delete obsolete view files

The four old view files are no longer referenced from `ConnectSheet`. Delete them. Xcode synchronized folders pick up filesystem deletions automatically — no pbxproj edit required.

**Files:**
- Delete: `Clave/Views/Home/Connect/ConnectMethodCard.swift`
- Delete: `Clave/Views/Home/Connect/ConnectShowQRView.swift`
- Delete: `Clave/Views/Home/Connect/ConnectScanQRView.swift`
- Delete: `Clave/Views/Home/Connect/ConnectPasteView.swift`

- [ ] **Step 1: Confirm none of these files are referenced from anywhere else.**

Run:
```bash
cd ~/clave/Clave
grep -rn "ConnectMethodCard\|ConnectShowQRView\|ConnectScanQRView\|ConnectPasteView" --include="*.swift" .
```

Expected: only matches inside the four files themselves (their own `struct` declarations). If anything else matches, fix the reference before deleting.

- [ ] **Step 2: Delete the files via git.**

```bash
cd ~/clave/Clave
git rm Clave/Views/Home/Connect/ConnectMethodCard.swift
git rm Clave/Views/Home/Connect/ConnectShowQRView.swift
git rm Clave/Views/Home/Connect/ConnectScanQRView.swift
git rm Clave/Views/Home/Connect/ConnectPasteView.swift
```

- [ ] **Step 3: Build to confirm nothing breaks.**

Run: `xcodebuild -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`

If it fails: a hidden reference exists somewhere. Re-run the grep from Step 1, find the reference, fix it. Most likely culprits: a `#Preview` in another file that imports one of these views, or a test file.

- [ ] **Step 4: Commit.**

```bash
cd ~/clave/Clave
git commit -m "refactor(connect): delete obsolete ConnectMethodCard/ShowQR/ScanQR/Paste views"
```

---

## Task 6 — Run unit tests to confirm no regression in adjacent code

The existing test suite covers `NostrConnectParser`, multi-account routing, `LightSigner`, etc. None of those are touched by this refactor, but run them to confirm the build is clean across the test target as well.

- [ ] **Step 1: Run the full test suite.**

Run:
```bash
cd ~/clave/Clave
xcodebuild test -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **` with the same pass count as pre-refactor. If any tests fail, read the failure messages — they should be unrelated to this redesign (touching `NostrConnectParser` or `AppState.handleNostrConnect` would be out of scope for this plan; investigate before continuing).

- [ ] **Step 2: No commit needed (tests didn't change).**

---

## Task 7 — Verify HomeView empty-state CTA changes (already in working tree)

The icon swap (`plus.circle.fill` → `plus`) and `.tint(theme.accent)` are already applied to `Clave/Views/Home/HomeView.swift:366-398` from the brainstorm session. Verify they're still in the working tree, build, and commit them as part of this redesign branch.

- [ ] **Step 1: Confirm the working-tree changes are still present.**

Run:
```bash
cd ~/clave/Clave
git diff Clave/Views/Home/HomeView.swift | grep -E "^\+.*plus[^.]|^\+.*tint\(theme" | head -5
```

Expected output should include:
- `+                    Label("Connect a Client", systemImage: "plus")`
- `+                .tint(theme.accent)`

If neither line appears, re-apply the diff per the spec section "Bonus: HomeView empty-state CTA":
1. In `emptyClientsView`, swap `plus.circle.fill` → `plus` (with the explanatory comment).
2. Compute `let theme = AccountTheme.forAccount(pubkeyHex: appState.currentAccount?.pubkeyHex ?? "")` at the top of the var, change the `HStack` to `return HStack`, and add `.tint(theme.accent)` after `.buttonStyle(.borderedProminent)`.

- [ ] **Step 2: Build to confirm the changes compile.**

Run: `xcodebuild -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -10`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Stage ONLY the emptyClientsView lines in HomeView.swift, leaving the parallel approve-pending WIP unstaged.**

The repo has parallel WIP from the approve-pending sprint that touches other parts of `HomeView.swift`. Use `git add -p` to interactively stage only the changes inside `emptyClientsView`:

```bash
cd ~/clave/Clave
git add -p Clave/Views/Home/HomeView.swift
```

For each hunk, type `y` to stage the hunk if it's inside `emptyClientsView` (lines roughly 366-400), `n` otherwise. After staging, verify:

```bash
git diff --cached Clave/Views/Home/HomeView.swift
```

Should show only the icon swap + tint addition. If it shows more, run `git reset Clave/Views/Home/HomeView.swift` and start over more carefully.

- [ ] **Step 4: Commit.**

```bash
git commit -m "fix(home): make empty-state Connect a Client CTA visible + AccountTheme-tinted

Two coupled fixes for the empty-state primary CTA in HomeView.emptyClientsView:

1. plus.circle.fill icon was rendering invisibly because the negative-
   space plus showed the same color as the borderedProminent button
   background. Swap to plain \`plus\` glyph.

2. Add .tint(theme.accent) so the CTA's prominent fill matches the
   active account's gradient identity, consistent with the smaller
   Pair New Connection row that already uses theme.accent.

Folded into the ConnectSheet redesign per the spec at
docs/superpowers/specs/2026-05-04-connect-sheet-redesign-design.md."
```

---

## Task 8 — Manual on-device verification (the 11-step plan from the spec)

Archive an internal-only TestFlight build, install on a real device, and walk through the spec's verification plan. This is the primary regression check for a UI refactor of this scope.

- [ ] **Step 1: Bump pbxproj for a fresh internal-TF build number.**

Find the current `CURRENT_PROJECT_VERSION` and bump by one. Per HANDOFF.md, the latest archived build is 51 (or higher if the parallel approve-pending sprint shipped first). Use `Edit` with `replace_all: true` on the literal `CURRENT_PROJECT_VERSION = N;` string:

```bash
cd ~/clave/Clave
grep -c "CURRENT_PROJECT_VERSION = " Clave.xcodeproj/project.pbxproj
# Expected: 8
```

Then via Edit tool: `CURRENT_PROJECT_VERSION = N;` → `CURRENT_PROJECT_VERSION = N+1;` (replace_all true). Verify all 8 occurrences updated.

- [ ] **Step 2: Commit the version bump.**

```bash
git add Clave.xcodeproj/project.pbxproj
git commit -m "build: bump pbxproj for ConnectSheet redesign internal-TF"
```

- [ ] **Step 3: Archive in Xcode, distribute Internal Testing.**

Manual:
1. Open `~/clave/Clave/Clave.xcodeproj` in Xcode.
2. Select scheme `Clave` + destination `Any iOS Device (arm64)`.
3. Product → Archive.
4. Organizer → Distribute App → App Store Connect → Upload.
5. Wait ~10-15min for ASC processing.
6. ASC → TestFlight → new build → Internal Testing → Add Build.

- [ ] **Step 4: Walk through the 11-step verification plan from the spec.**

Open the spec at `docs/superpowers/specs/2026-05-04-connect-sheet-redesign-design.md` and run through all 11 verification steps:

1. Bunker tab default + tap-to-copy (QR, URI text card, Copy button — three affordances)
2. New secret rotation
3. Switch to Nostrconnect tab (camera permission first-time prompt)
4. Scan flow — show a `nostrconnect://` QR from clave.casa or any client
5. Paste flow — copy a URI, paste, hit Done
6. Invalid paste — type "not a uri", verify red error border + caption
7. Help link — tap, read sheet, dismiss
8. Camera denied — Settings → Privacy → Camera → revoke Clave, reopen tab, verify placeholder
9. Empty-state CTA — visible plus glyph + tint matches active account (switch accounts to verify color updates)
10. Deeplink path — clave.casa Sign In QR via system camera should bypass ConnectSheet entirely (DeeplinkRouter still routes directly to ApprovalSheet)
11. Multi-account context bar — render with 2+ accounts, switch, verify the bar updates

Document any failures in `~/hq/clave/troubleshooting/` per project convention.

- [ ] **Step 5: If smoke is clean, push the branch and open a PR.**

```bash
cd ~/clave/Clave
git push -u origin docs/connect-sheet-redesign
gh pr create \
  --title "feat: ConnectSheet redesign — single sheet with segmented control" \
  --body "Replaces the 3-card method chooser with a single sheet whose body
switches between Bunker and Nostrconnect tabs via a segmented control.
Bundles a small visibility + tint fix on HomeView's empty-state Connect
a Client CTA.

Spec: docs/superpowers/specs/2026-05-04-connect-sheet-redesign-design.md
Plan: docs/superpowers/plans/2026-05-04-connect-sheet-redesign.md

## Test plan
- [x] Internal TF smoke covered all 11 spec verification steps
- [x] xcodebuild test passes (no test changes; regression check only)

## Files
**Created:** ConnectHelpSheet.swift, ConnectBunkerTabView.swift, ConnectNostrconnectTabView.swift
**Rewritten:** ConnectSheet.swift
**Modified:** HomeView.swift (emptyClientsView icon + tint)
**Deleted:** ConnectMethodCard.swift, ConnectShowQRView.swift, ConnectScanQRView.swift, ConnectPasteView.swift"
```

---

## Self-review

**Spec coverage check:** Walked through each section of the spec — every Goal has a corresponding Task: structural change (Task 4), bunker URI discoverability (Task 2), nostrconnect inline composition (Task 3), help link (Task 1 + Task 3), camera denial (Task 3), HomeView fix (Task 7). Each Edge Case in the spec has a corresponding implementation in Task 3 (camera-denied + first-grant) or is explicitly out-of-band (deeplink path is unchanged, empty bunker URI is in Task 2). The 11-step verification plan is referenced explicitly in Task 8.

**Placeholder scan:** No "TBD" / "TODO" / "implement later" / "fill in details" in the plan. Every step has actual content. Code blocks have complete code, not snippets-with-elision. The `git add -p` step in Task 7 is interactive but the instruction is concrete (match the lines in `emptyClientsView`).

**Type/symbol consistency:** `appState.bunkerURI`, `appState.rotateBunkerSecret`, `appState.handleNostrConnect`, `NostrConnectParser.parse`, `NostrConnectParser.ParsedURI`, `ClientPermissions`, `ApprovalSheet`, `QRCodeView`, `ConnectAccountContextBar`, `AccountTheme.forAccount(pubkeyHex:)` — all referenced consistently and match the actual API in the codebase (verified via grep during context exploration).

**Spec-vs-plan deltas:** None. The plan implements the spec's chosen design exactly. The HomeView changes are in Task 7 which the spec describes in the "Bonus" section. The spec's "Out of scope" items (long URI overflow handling, copy A/B testing, hybrid label fallback) are not in the plan, as intended.

---

## Effort estimate

- Tasks 1-5: ~4-6 hours of code + per-task build verification.
- Task 6: ~5 minutes (running existing tests).
- Task 7: ~10 minutes (already-applied changes, isolated commit).
- Task 8: ~30-60 minutes (archive + ASC processing wait + on-device walkthrough).

**Total: ~6-8 hours from clean branch to PR-ready.**
