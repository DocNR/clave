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
