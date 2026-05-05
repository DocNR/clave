import SwiftUI

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
                QRCodeView.makeImage(for: appState.bunkerURI)
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
