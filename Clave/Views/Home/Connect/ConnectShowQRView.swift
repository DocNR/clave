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
