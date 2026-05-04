import SwiftUI

/// Horizontal scrolling avatar strip — Stage C account picker.
/// Replaces the build-37 interim Menu (`aa194a9`) on HomeView.
///
/// - Always visible (post build-46 device-test feedback) — even at single-
///   account, so the trailing "+" pill stays accessible for adding new
///   accounts from Home. Previously auto-hidden at `accounts.count == 1`
///   for "no UI noise"; reverted because the "+" affordance value
///   outweighs the noise concern. At zero accounts ContentView routes to
///   OnboardingView before this view renders, so the empty-strip case
///   never occurs in practice.
/// - Active pill: 5pt gradient ring matching account's AccountTheme.
/// - Inactive pill: 1pt subtle hairline ring (Color.secondary.opacity(0.25)).
/// - Sits directly on HomeView's ambient gradient — no frosted card.
/// - Tap non-active pill → switchToAccount.
/// - Tap active pill → push AccountDetailView (via NavigationLink in HomeView).
/// - Long-press any pill → push AccountDetailView WITHOUT switching active.
/// - Trailing "+" pill → present AddAccountSheet.
struct AccountStripView: View {
    @Environment(AppState.self) private var appState
    /// Called when the user taps the trailing "+" pill. The parent decides
    /// whether to open AddAccountSheet or show the cap-reached alert (so the
    /// alert fires BEFORE sheet presentation, not after).
    let onAddTapped: () -> Void

    /// Hardcoded — sizing locked in the 2026-05-02 Home redesign brainstorm.
    private let pillSize: CGFloat = 60
    private let ringPadding: CGFloat = 5

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(appState.accounts) { account in
                    accountPill(account)
                }
                addPill
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
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
            onAddTapped()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .frame(width: pillSize, height: pillSize)
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }
                Text("Add")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: pillSize + 14)
            }
        }
        .buttonStyle(.plain)
    }
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
            // Opaque backing so PFPs with transparent backgrounds (robohash,
            // some kind:0 avatars) don't reveal the gradient ring through the
            // image. Uses systemBackground so it adapts light/dark.
            ZStack {
                Color(.systemBackground)
                Image(uiImage: cachedImage)
                    .resizable()
                    .scaledToFill()
            }
        } else {
            AvatarView(pubkeyHex: account.pubkeyHex,
                       name: labelText,
                       size: pillSize)
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
            VStack(spacing: 6) {
                ZStack {
                    if isActive {
                        Circle()
                            .fill(LinearGradient(colors: [theme.start, theme.end],
                                                 startPoint: .topLeading,
                                                 endPoint: .bottomTrailing))
                            .frame(width: pillSize + ringPadding * 2,
                                   height: pillSize + ringPadding * 2)
                    } else {
                        Circle()
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            .frame(width: pillSize + ringPadding * 2,
                                   height: pillSize + ringPadding * 2)
                    }
                    avatarView
                        .frame(width: pillSize, height: pillSize)
                        .clipShape(Circle())
                }
                Text(labelText)
                    .font(.system(size: 11, weight: isActive ? .heavy : .semibold))
                    .foregroundStyle(isActive ? theme.accent : Color.primary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: pillSize + 14)
            }
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0.5) {
            didLongPress = true
            onPushDetail()
        }
    }
}

