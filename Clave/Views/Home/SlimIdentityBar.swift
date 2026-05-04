import SwiftUI

/// Themed mini-banner identity row below AccountStripView. Solid gradient
/// background (matches AccountDetailView's full-bleed banner in miniature),
/// mini avatar, @petname, npub, copy button, chevron. Tap anywhere on the row
/// pushes AccountDetailView for the current account — same path the active-pill
/// tap uses, via `appState.pendingDetailPubkey`.
///
/// 2026-05-02 redesign: replaces the build-38 wash + accent-stroke treatment
/// with a solid theme gradient for visual continuity with the detail view.
struct SlimIdentityBar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let current = appState.currentAccount {
            let theme = AccountTheme.forAccount(pubkeyHex: current.pubkeyHex)
            Button {
                appState.pendingDetailPubkey = current.pubkeyHex
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } label: {
                HStack(spacing: 12) {
                    miniAvatar(for: current)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("@\(current.displayLabel)")
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(truncatedNpub)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    copyButton
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(
                            colors: [theme.start, theme.end],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing))
                        .shadow(color: theme.start.opacity(0.25), radius: 8, x: 0, y: 1)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func miniAvatar(for account: Account) -> some View {
        let initial = String(account.displayLabel.first ?? "?").uppercased()
        ZStack {
            if let img = cachedAvatar(for: account) {
                // Opaque backing so PFPs with transparent backgrounds (robohash,
                // some kind:0 avatars) don't show the slim banner's theme
                // gradient through the image.
                Color(.systemBackground)
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.22)
                Text(initial)
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 1.5))
    }

    /// Per-account cached profile image (same source as AccountStripView).
    private func cachedAvatar(for account: Account) -> UIImage? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConstants.appGroup
        ) else { return nil }
        let url = container.appendingPathComponent("cached-profile-\(account.pubkeyHex).dat")
        guard let data = try? Data(contentsOf: url),
              let img = UIImage(data: data) else { return nil }
        return img
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = appState.npub
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.white.opacity(0.22))
                )
        }
        .buttonStyle(.plain)
    }

    private var truncatedNpub: String {
        let n = appState.npub
        guard n.count > 20 else { return n }
        return String(n.prefix(12)) + "…" + String(n.suffix(6))
    }
}
