import SwiftUI

/// Small "Connecting to @petname" bar shown at the top of each focused
/// connect view (Show QR / Scan / Paste). Mini themed dot matches the
/// active account's AccountTheme; reads displayLabel for the petname.
///
/// Per design-system.md treatment C — sits in the identity zone with
/// theme-derived accent. Never tappable.
struct ConnectAccountContextBar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let account = appState.currentAccount {
            let theme = AccountTheme.forAccount(pubkeyHex: account.pubkeyHex)
            HStack(spacing: 8) {
                Circle()
                    .fill(LinearGradient(
                        colors: [theme.start, theme.end],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(theme.accent.opacity(0.6), lineWidth: 1.5))
                Text("Connecting to ")
                    .foregroundStyle(.secondary)
                + Text("@\(account.displayLabel)")
                    .foregroundStyle(.primary)
                    .fontWeight(.semibold)
                Spacer()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}
