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
    /// Bound to ConnectSheet's parsedURI. When this transitions back to
    /// nil (e.g. ApprovalSheet was cancelled without completing),
    /// the view resets isScanning + clears any scanError so the camera
    /// resumes. Without this, a successful scan permanently sets
    /// isScanning = false and the viewfinder freezes after cancel
    /// because .onAppear doesn't re-fire (the view never unmounts —
    /// the segmented control swaps body inline rather than pushing).
    let parsedURI: NostrConnectParser.ParsedURI?
    let onParsed: (NostrConnectParser.ParsedURI) -> Void

    @State private var pasteText = ""
    @State private var pasteError: String?
    @State private var showHelp = false
    @State private var cameraAuthState: AVAuthorizationStatus = .notDetermined
    @State private var isScanning = true
    @State private var scanError: String?

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

    @ViewBuilder
    private var cameraSection: some View {
        switch cameraAuthState {
        case .authorized:
            ZStack {
                QRScannerView(
                    isScanning: isScanning,
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

    private var pasteSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Or paste a URI")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
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

    private func handleScannedCode(_ code: String) {
        // Drop any AVFoundation delegate callbacks that arrive after we've
        // already accepted a successful scan. Without this guard, the
        // `isScanning = false` write below schedules a re-render but the
        // metadata output queue can fire multiple times before SwiftUI
        // re-evaluates QRScannerView and calls stop() — leading to
        // duplicate onParsed invocations.
        guard isScanning else { return }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let parsed = try NostrConnectParser.parse(trimmed)
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
