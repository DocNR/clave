import SwiftUI

/// Sheet presented when a nostrconnect:// deeplink arrives and the user
/// has 2+ accounts. Lists accounts with their themed avatars; user taps
/// one to bind the in-flight URI to that account. ApprovalSheet then
/// presents with boundAccountPubkey set.
///
/// Cancel discards the deeplink — user must re-tap the source link to
/// retry.
struct DeeplinkAccountPicker: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let parsedURI: NostrConnectParser.ParsedURI
    let onPick: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                headerBlock
                    .padding(.horizontal)
                    .padding(.top, 8)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(appState.accounts) { account in
                            accountRow(for: account)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .navigationTitle("Connect with which account?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(Color(.systemGroupedBackground))
    }

    private var headerBlock: some View {
        Text("Choose the identity to use for **\(clientLabel)**.")
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
    }

    private var clientLabel: String {
        parsedURI.name ?? "this connection"
    }

    private func accountRow(for account: Account) -> some View {
        let theme = AccountTheme.forAccount(pubkeyHex: account.pubkeyHex)
        let isCurrent = account.pubkeyHex == appState.currentAccount?.pubkeyHex
        return Button {
            onPick(account.pubkeyHex)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    if isCurrent {
                        Circle()
                            .fill(LinearGradient(colors: [theme.start, theme.end],
                                                 startPoint: .topLeading,
                                                 endPoint: .bottomTrailing))
                            .frame(width: 68, height: 68)
                    }
                    AvatarView(pubkeyHex: account.pubkeyHex,
                               name: account.displayLabel,
                               size: 60)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("@\(account.displayLabel)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(String(account.pubkeyHex.prefix(12)) + "…")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isCurrent {
                    Text("Current")
                        .font(.caption2.bold())
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(theme.start.opacity(0.15), in: Capsule())
                }
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
