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

        // NavigationLink wraps the inner content so tap on active pill pushes
        // AccountDetailView (Task 4). Non-active pill suppresses the link via
        // a separate Button overlay below.
        NavigationLink(value: AccountNavTarget.detail(pubkey: account.pubkeyHex)) {
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
                    avatarPlaceholder(for: account)
                        .frame(width: pillSize, height: pillSize)
                        .clipShape(Circle())
                }
                Text(labelText(for: account))
                    .font(.system(size: 9, weight: isActive ? .heavy : .semibold))
                    .foregroundStyle(isActive ? theme.accent : Color.primary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: pillSize + 8)
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            // Tap on non-active pill switches account instead of navigating.
            // For active pill, navigation runs (the NavigationLink wins).
            TapGesture().onEnded {
                if !isActive {
                    appState.switchToAccount(pubkey: account.pubkeyHex)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
        )
        .onLongPressGesture(minimumDuration: 0.5) {
            // Long-press always opens detail without switching, even on
            // active. Override the simultaneousGesture switch above by
            // doing nothing here — the NavigationLink fires on tap-up
            // only if the gesture wasn't a long-press, so explicit
            // navigation here on long-press requires programmatic push.
            // SwiftUI's NavigationLink(value:) consumes the tap; the
            // long-press fires before tap-up resolves. We rely on the
            // user performing the long-press THEN releasing — which iOS
            // treats as a long-press, not a tap, and the NavigationLink
            // doesn't fire. Trigger nav via app router state.
            appState.pendingDetailPubkey = account.pubkeyHex
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
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

    /// Avatar placeholder — letter on neutral gradient. Real PFPs from
    /// kind:0 picture URLs land here in a future iteration; for now we
    /// always show the letter.
    @ViewBuilder
    private func avatarPlaceholder(for account: Account) -> some View {
        let initial = String(labelText(for: account).first ?? "?").uppercased()
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

    /// Display label preference: petname → kind:0 displayName → truncated pubkey.
    private func labelText(for account: Account) -> String {
        if let p = account.petname, !p.isEmpty { return p }
        if let d = account.profile?.displayName, !d.isEmpty { return d }
        let h = account.pubkeyHex
        guard h.count > 8 else { return h }
        return String(h.prefix(8))
    }
}

/// Navigation target enum used by HomeView's NavigationStack to route
/// to AccountDetailView. Defined here because the strip is the primary
/// origin; SettingsView (Task 6) and the long-press handler also use it.
enum AccountNavTarget: Hashable {
    case detail(pubkey: String)
}
