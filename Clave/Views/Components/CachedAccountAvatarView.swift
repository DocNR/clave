import SwiftUI

/// Account avatar that reads the cached profile picture from the app-group
/// container (`cached-profile-<pubkey>.dat`). Falls back to `AvatarView`'s
/// gradient + initials when no cached image exists — account hasn't fetched
/// kind:0 yet, profile has no `pictureURL`, or the fetch failed.
///
/// Synchronous disk read in `body` — files are small (~50KB PFPs) and the
/// read happens during view body evaluation. Renders instantly on every
/// sheet presentation, with no network round-trip or AsyncImage fetch
/// flicker.
///
/// Cache is populated by `AppState.cacheImage(from:pubkey:)` whenever a
/// kind:0 profile fetch surfaces a `pictureURL`. The same on-disk file is
/// read by `AccountStripView`, `AccountDetailView`, `SettingsView`, and
/// `SlimIdentityBar` — this view consolidates the pattern for the
/// connect-side surfaces (ConnectAccountPicker, BunkerURIRender,
/// ApprovalSheet account chips / progress rows).
struct CachedAccountAvatarView: View {
    let pubkeyHex: String
    /// Optional display label, forwarded to `AvatarView` for initials
    /// rendering when no cached image is present. Doesn't influence the
    /// cached-image path.
    var displayLabel: String? = nil
    var size: CGFloat = 48

    var body: some View {
        if let cached = cachedImage {
            // Opaque backing so PFPs with transparent backgrounds
            // (robohash, some kind:0 avatars) don't reveal whatever
            // sits behind through the image. Matches the pattern in
            // AccountStripView's AccountPillView.avatarView.
            ZStack {
                Color(.systemBackground)
                Image(uiImage: cached)
                    .resizable()
                    .scaledToFill()
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            AvatarView(pubkeyHex: pubkeyHex,
                       name: displayLabel,
                       size: size)
        }
    }

    private var cachedImage: UIImage? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConstants.appGroup
        ) else { return nil }
        let url = container.appendingPathComponent("cached-profile-\(pubkeyHex).dat")
        guard let data = try? Data(contentsOf: url),
              let img = UIImage(data: data) else { return nil }
        return img
    }
}
