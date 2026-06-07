import SwiftUI
import AVFoundation

/// How a nostrconnect URI was acquired in the Connect flow. Drives the
/// post-Approve "Connecting…" overlay copy: paste implies the client
/// app is on the same device (user copied the URI here), so the user
/// should switch back to it during the handshake; a QR scan implies
/// the client is on another screen, so staying foregrounded in Clave
/// is fine. Background: iOS suspends the client app's WebSocket
/// subscription once it loses foreground, so a same-device user who
/// follows "stay in Clave" advice never receives the connect-response.
enum NostrConnectURISource {
    case paste
    case qrScan
}

/// The primary surface inside the Connect tab. Hosts (top to bottom):
///   - QR scanner viewfinder (when camera authorized)
///   - Paste-from-clipboard button + URI text field
///   - "Share a code from Clave" action card (pushes to bunker view)
///   - "What's the difference between Nostrconnect and Bunker?" help link
///
/// Camera permission handling, scan deduplication, and paste validation
/// originated from the deleted ConnectNostrconnectTabView. The bunker action
/// card and the educational help-link copy were added during Phase 1 smoke
/// fixes — the card moved up from a buried secondary position to right
/// below the paste field, and the help sheet now explains both methods
/// (nostrconnect vs bunker) plus the same-device pairing gotcha.
struct ConnectNostrConnectSurface: View {

    @Environment(AppState.self) private var appState

    /// Bound by parent (ConnectTabView, future Task 7). Triggers presentation
    /// of ConnectAccountPicker → ApprovalSheet.
    let parsedURI: NostrConnectParser.ParsedURI?
    let onParsed: (NostrConnectParser.ParsedURI, NostrConnectURISource) -> Void
    let onShowBunker: () -> Void

    @State private var pasteText = ""
    @State private var pasteError: String?
    @State private var showHelp = false
    @State private var cameraAuthState: AVAuthorizationStatus = .notDetermined
    @State private var isScanning = true
    @State private var scanError: String?
    /// Last QR code value we accepted via the scanner. The scanner auto-
    /// resumes when ApprovalSheet dismisses (so the user can scan a
    /// different QR after a mis-scan), but the same QR is almost always
    /// still in frame and gets re-detected within ~1s, looping the user
    /// back into ApprovalSheet they just dismissed. We dedup against this
    /// value to break the loop. A different QR has a different code
    /// (each nostrconnect URI carries a fresh secret) so legitimate
    /// retries with a new code aren't blocked. Cleared when this view
    /// re-mounts (i.e. ConnectSheet is reopened).
    @State private var lastAcceptedScanCode: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                cameraSection
                pasteSection
                bunkerActionCard
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
        .onChange(of: parsedURI?.id) { _, newId in
            // ApprovalSheet just dismissed without completing pairing
            // (cancel button OR error path). Reset the scanner so the
            // user can try again. Without this the viewfinder is frozen
            // because handleScannedCode set isScanning = false on the
            // successful detection that triggered ApprovalSheet to
            // present.
            if newId == nil {
                isScanning = true
                scanError = nil
            }
        }
    }

    // MARK: - Camera section

    @ViewBuilder
    private var cameraSection: some View {
        switch cameraAuthState {
        case .authorized:
            ZStack {
                QRScannerView(
                    // Gate the camera on the Connect tab being selected.
                    // The TabView keeps this surface mounted after the
                    // first visit, so without this the AVCaptureSession
                    // would stay live (camera indicator on) on every other
                    // tab. `isScanning` still drives scan dedup/pause; this
                    // adds "and the user is actually looking at us".
                    isScanning: isScanning && appState.selectedTab == .connect,
                    onCode: handleScannedCode,
                    onPermissionDenied: {
                        cameraAuthState = .denied
                    }
                )
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if let scanError {
                    VStack {
                        Spacer()
                        Text(scanError)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                            .padding(.bottom, 10)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
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

    // MARK: - Paste section

    private var pasteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Or paste a URI")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Button {
                pasteFromClipboard()
            } label: {
                Label("Paste Nostrconnect URI", systemImage: "doc.on.clipboard")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            TextField("nostrconnect://...", text: $pasteText)
                .font(.system(.caption, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.URL)
                .submitLabel(.go)
                .padding(10)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(pasteError == nil ? Color(.separator) : Color.red, lineWidth: 1)
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
                Text("What's the difference between Nostrconnect and Bunker?")
                    .multilineTextAlignment(.leading)
            }
            .font(.footnote)
            .fontWeight(.medium)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .padding(.top, 4)
    }

    // MARK: - Bunker action card

    /// Promoted from a small "secondary affordance" at the bottom of the
    /// surface to a more prominent action card right after the paste field.
    /// Same destination (the bunker child route) — better discoverability for
    /// users who arrived here via the Connect tab rather than via a client app
    /// presenting them a `nostrconnect://` URI to paste.
    private var bunkerActionCard: some View {
        Button {
            onShowBunker()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "qrcode")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Share a code from Clave")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Generate a bunker URI for another app to use")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Validation + scan handling

    private func validateAndSubmit() {
        let trimmed = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let parsed = try NostrConnectParser.parse(trimmed)
            pasteError = nil
            onParsed(parsed, .paste)
        } catch {
            pasteError = "That doesn't look like a valid nostrconnect URI."
        }
    }

    private func pasteFromClipboard() {
        guard let clipboard = UIPasteboard.general.string,
              !clipboard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pasteError = "Clipboard is empty."
            return
        }
        pasteText = clipboard
        validateAndSubmit()
    }

    private func handleScannedCode(_ code: String) {
        // Drop any AVFoundation delegate callbacks that arrive after we've
        // already accepted a successful scan. Without this guard, the
        // `isScanning = false` write below schedules a re-render but the
        // metadata output queue can fire multiple times before SwiftUI
        // re-evaluates QRScannerView and calls stop() — leading to
        // duplicate onParsed invocations.
        guard isScanning else { return }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        // Dedup against the last accepted QR. After ApprovalSheet
        // dismisses, parsedURI flips back to nil and the onChange above
        // re-arms the scanner — but the QR is almost always still in
        // frame, so without this guard the user gets bounced straight
        // back into ApprovalSheet for the same URI they just cancelled.
        // A new client URI has a new secret (and therefore a new code),
        // so legitimate retries from a different source aren't blocked.
        if trimmed == lastAcceptedScanCode { return }
        do {
            let parsed = try NostrConnectParser.parse(trimmed)
            isScanning = false
            lastAcceptedScanCode = trimmed
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onParsed(parsed, .qrScan)
        } catch let error as NostrConnectParser.ParseError {
            switch error {
            case .invalidScheme: scanError = "Not a Nostrconnect code"
            case .missingPubkey: scanError = "Missing client public key"
            case .missingRelay:  scanError = "Missing relay parameter"
            case .missingSecret: scanError = "Missing secret parameter"
            case .invalidURL:    scanError = "Invalid URI format"
            }
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
