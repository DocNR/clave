import SwiftUI

/// Text-only identity row below AccountStripView. Shows current account's
/// `@petname • npub… [copy]`. No avatar (strip already shows it).
/// Background carries a 22% gradient wash matching the active account.
struct SlimIdentityBar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let current = appState.currentAccount {
            let theme = AccountTheme.forAccount(pubkeyHex: current.pubkeyHex)
            HStack(spacing: 10) {
                Text("@\(displayLabel(for: current))")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(.primary)
                Text(truncatedNpub)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                copyButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(LinearGradient(
                        colors: [theme.start.opacity(0.22), theme.end.opacity(0.16)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11)
                            .stroke(theme.start.opacity(0.35), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = appState.npub
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.92))
                        .shadow(color: Color.black.opacity(0.06), radius: 1, y: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func displayLabel(for account: Account) -> String {
        if let p = account.petname, !p.isEmpty { return p }
        if let d = account.profile?.displayName, !d.isEmpty { return d }
        return String(account.pubkeyHex.prefix(8))
    }

    private var truncatedNpub: String {
        let n = appState.npub
        guard n.count > 20 else { return n }
        return String(n.prefix(12)) + "…" + String(n.suffix(6))
    }
}
