import SwiftUI

/// Renders a bunker URI (QR + text card + action buttons) for a specific
/// signer account. Mirrors the visual layout of `ConnectBunkerTabView` exactly,
/// but binds to an explicit `signerPubkey` rather than the implicit
/// `currentAccount`. This makes it safe to show a different account's bunker
/// URI without switching the active account.
///
/// Used by `ConnectBunkerView` after the account picker resolves the signer.
struct BunkerURIRender: View {

    @Environment(AppState.self) private var appState

    let signerPubkey: String

    @State private var showQR = false
    @State private var copiedBunker = false
    @State private var showCapAlert = false

    // MARK: - Computed

    private var bunkerURI: String {
        // `bunkerSecretsTick` observation forces re-evaluation after rotation.
        let _ = appState.bunkerSecretsTick
        return appState.bunkerURI(for: signerPubkey) ?? ""
    }

    /// Live paired-client count for the selected signer. Mirrors the
    /// same pattern as `ConnectBunkerTabView.isAtPairingCap` but scoped to
    /// the explicit signer rather than `currentAccount`.
    private var isAtPairingCap: Bool {
        let _ = appState.bunkerSecretsTick
        return SharedStorage.getConnectedClients(for: signerPubkey).count >= Account.maxClientsPerAccount
    }

    // MARK: - Body

    var body: some View {
        let _ = appState.bunkerSecretsTick
        if bunkerURI.isEmpty {
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
                QRCodeView(content: bunkerURI)
            }
            .alert("Connection limit reached", isPresented: $showCapAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("You've reached the \(Account.maxClientsPerAccount)-client cap on this account. Unpair a client in Settings → Clients to pair a new one.")
            }
        }
    }

    // MARK: - Subviews

    private var qrCard: some View {
        VStack(spacing: 8) {
            Button {
                showQR = true
            } label: {
                QRCodeView.makeImage(for: bunkerURI)
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
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(bunkerURI)
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
        let theme = AccountTheme.forAccount(pubkeyHex: signerPubkey)
        return HStack(spacing: 8) {
            Button {
                copyBunkerURI()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: copiedBunker ? "checkmark" : "doc.on.doc")
                    Text(copiedBunker ? "Copied" : "Copy URI")
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(copiedBunker ? .green : theme.accent)

            Button {
                if isAtPairingCap {
                    showCapAlert = true
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                } else {
                    appState.rotateBunkerSecret(for: signerPubkey)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
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

    // MARK: - Actions

    private func copyBunkerURI() {
        UIPasteboard.general.setItems(
            [["public.utf8-plain-text": bunkerURI]],
            options: [.expirationDate: Date().addingTimeInterval(120)]
        )
        copiedBunker = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedBunker = false }
    }
}
