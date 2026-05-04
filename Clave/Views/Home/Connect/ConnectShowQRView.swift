import SwiftUI
import CoreImage.CIFilterBuiltins

/// Focused view for the "Show my QR" connection method. User shows the
/// bunker URI to a client (display + QR + copy). Single-use secret rotates
/// when a client successfully pairs.
struct ConnectShowQRView: View {
    @Environment(AppState.self) private var appState
    @State private var showQR = false
    @State private var copiedBunker = false

    /// QR generator — same CIFilter shape QRCodeView uses for the full-screen
    /// sheet. Inlined here so the bunker QR is visible without an extra tap.
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
                VStack(spacing: 6) {
                    qrImage(for: appState.bunkerURI)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(12)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: 240)
                    Text("Tap for full screen")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
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
