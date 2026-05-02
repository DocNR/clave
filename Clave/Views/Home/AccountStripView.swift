import SwiftUI

/// Horizontal scrolling avatar strip — Stage C account picker.
/// Replaces the build-37 interim Menu (`aa194a9`) on HomeView.
///
/// - Auto-hides when `accounts.count == 1` (single-account user sees same
///   Home as build 31; no UI noise).
/// - Active pill: 3pt gradient ring matching account's AccountTheme.
/// - Tap non-active pill → switchToAccount.
/// - Tap active pill → push AccountDetailView (via NavigationLink in HomeView).
/// - Long-press any pill → push AccountDetailView WITHOUT switching active.
/// - Trailing "+" pill → present AddAccountSheet (Task 3).
struct AccountStripView: View {
    @Environment(AppState.self) private var appState
    @Binding var showAddSheet: Bool

    /// Hardcoded — ring + pill sizing tuned per spec mockups (v4).
    private let pillSize: CGFloat = 38
    private let ringPadding: CGFloat = 3

    var body: some View {
        if appState.accounts.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(appState.accounts) { account in
                        accountPill(account)
                    }
                    addPill
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            }
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.white.opacity(0.4), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    // MARK: - Per-account pill

    @ViewBuilder
    private func accountPill(_ account: Account) -> some View {
        let isActive = account.pubkeyHex == appState.currentAccount?.pubkeyHex
        let theme = AccountTheme.forAccount(pubkeyHex: account.pubkeyHex)
        AccountPillView(
            account: account,
            isActive: isActive,
            pillSize: pillSize,
            ringPadding: ringPadding,
            theme: theme,
            labelText: account.displayLabel,
            cachedImage: cachedAvatar(for: account),
            onSwitch: {
                appState.switchToAccount(pubkey: account.pubkeyHex)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            },
            onPushDetail: {
                appState.pendingDetailPubkey = account.pubkeyHex
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        )
    }

    // MARK: - Cached avatar helper

    /// Load the per-account cached profile image from app-group storage.
    /// Returns nil if no image is cached (account hasn't fetched profile yet,
    /// or kind:0 has no pictureURL). Synchronous read — files are small (~50KB
    /// PFPs) and the read happens during view body evaluation.
    private func cachedAvatar(for account: Account) -> UIImage? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConstants.appGroup
        ) else { return nil }
        let url = container.appendingPathComponent("cached-profile-\(account.pubkeyHex).dat")
        guard let data = try? Data(contentsOf: url),
              let img = UIImage(data: data) else { return nil }
        return img
    }

    // MARK: - Add pill

    private var addPill: some View {
        Button {
            showAddSheet = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .frame(width: pillSize, height: pillSize)
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }
                Text("Add")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: pillSize + 8)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

}

// MARK: - AccountPillView

/// Per-account pill extracted into a child struct so it can hold a local
/// `@State` flag that suppresses the tap-up that follows a long-press.
///
/// Without this flag, `.simultaneousGesture(TapGesture)` fires on finger-lift
/// even after a long-press, which would call `onSwitch` for a non-active pill
/// that the user only intended to peek at via long-press.
private struct AccountPillView: View {
    let account: Account
    let isActive: Bool
    let pillSize: CGFloat
    let ringPadding: CGFloat
    let theme: AccountTheme
    let labelText: String
    let cachedImage: UIImage?
    let onSwitch: () -> Void
    let onPushDetail: () -> Void

    @State private var didLongPress = false

    @ViewBuilder
    private var avatarView: some View {
        if let cachedImage {
            Image(uiImage: cachedImage)
                .resizable()
                .scaledToFill()
        } else {
            AccountAvatarPlaceholder(label: labelText)
        }
    }

    var body: some View {
        Button {
            if didLongPress {
                didLongPress = false
                return
            }
            if isActive {
                onPushDetail()
            } else {
                onSwitch()
            }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    if isActive {
                        Circle()
                            .fill(LinearGradient(colors: [theme.start, theme.end],
                                                 startPoint: .topLeading,
                                                 endPoint: .bottomTrailing))
                            .frame(width: pillSize + ringPadding * 2,
                                   height: pillSize + ringPadding * 2)
                    }
                    avatarView
                        .frame(width: pillSize, height: pillSize)
                        .clipShape(Circle())
                }
                Text(labelText)
                    .font(.system(size: 9, weight: isActive ? .heavy : .semibold))
                    .foregroundStyle(isActive ? theme.accent : Color.primary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: pillSize + 8)
            }
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0.5) {
            didLongPress = true
            onPushDetail()
        }
    }
}

// MARK: - AccountAvatarPlaceholder

/// Letter-on-gradient avatar placeholder. Real PFPs from kind:0 picture
/// URLs land here in a future iteration; for now we always show the letter.
private struct AccountAvatarPlaceholder: View {
    let label: String

    var body: some View {
        let initial = String(label.first ?? "?").uppercased()
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.78), Color(white: 0.62)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
            Text(initial)
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(Color.white)
        }
    }
}
