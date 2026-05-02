import SwiftUI

/// Mini-bar prepended to ApprovalSheet's body. Makes the active signer
/// account unmistakable so users don't approve a request for the wrong
/// account when multi-account is active.
///
/// Looks up the account from a pubkey hex (typically request.signerPubkeyHex);
/// falls back to a truncated pubkey when no Account / petname / displayName
/// is available.
struct SigningAsHeader: View {
    @Environment(AppState.self) private var appState
    let signerPubkeyHex: String

    var body: some View {
        let theme = AccountTheme.forAccount(pubkeyHex: signerPubkeyHex)
        let label = displayLabel()

        HStack(spacing: 10) {
            avatarMini
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

    private var avatarMini: some View {
        let theme = AccountTheme.forAccount(pubkeyHex: signerPubkeyHex)
        let initial = String(displayLabel().first ?? "?").uppercased()
        return ZStack {
            LinearGradient(colors: [theme.start, theme.end],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(initial)
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white)
        }
        .frame(width: 24, height: 24)
        .clipShape(Circle())
    }

    private func displayLabel() -> String {
        guard let account = appState.accounts.first(where: { $0.pubkeyHex == signerPubkeyHex }) else {
            // Defensive — request signer should always be in accounts.
            return String(signerPubkeyHex.prefix(8))
        }
        if let p = account.petname, !p.isEmpty { return p }
        if let d = account.profile?.displayName, !d.isEmpty { return d }
        return String(account.pubkeyHex.prefix(8))
    }
}
