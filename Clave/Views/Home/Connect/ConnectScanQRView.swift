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
