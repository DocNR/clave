import SwiftUI

/// Mini-bar prepended to ApprovalSheet's body. Makes the active signer
/// account unmistakable so users don't approve a request for the wrong
/// account when multi-account is active.
///
/// Looks up the account from a pubkey hex (typically request.signerPubkeyHex);
/// falls back to a truncated pubkey when no Account / displayName is available.
struct SigningAsHeader: View {
    @Environment(AppState.self) private var appState
    let signerPubkeyHex: String

    var body: some View {
        let theme = AccountTheme.forAccount(pubkeyHex: signerPubkeyHex)
        let label = displayLabel()

        HStack(spacing: 10) {
            CachedAccountAvatarView(pubkeyHex: signerPubkeyHex,
                                    displayLabel: label,
                                    size: 24)
            HStack(spacing: 4) {
                Text("Signing as")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("@\(label)")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(LinearGradient(
                    colors: [theme.start.opacity(0.12), theme.end.opacity(0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(theme.start.opacity(0.4), lineWidth: 1)
                )
        )
    }

    private func displayLabel() -> String {
        appState.accounts.first(where: { $0.pubkeyHex == signerPubkeyHex })?.displayLabel
            ?? String(signerPubkeyHex.prefix(8))
    }
}
