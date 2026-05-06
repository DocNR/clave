import SwiftUI

/// Compact client identity header used at the top of both
/// `PendingRequestDetailView` and `ActivityDetailView`. Avatar +
/// resolved display name + monospaced truncated pubkey. Reads
/// the client's persisted name from `SharedStorage.getClientPermissions`
/// (legacy single-arg lookup is sufficient — UI display only, not
/// security-sensitive).
struct ClientIdentityHeader: View {
    let clientPubkey: String
    var avatarSize: CGFloat = 56

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(
                pubkeyHex: clientPubkey,
                name: persistedName,
                size: avatarSize
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(truncatedPubkey)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var persistedName: String? {
        SharedStorage.getClientPermissions(for: clientPubkey)?.name
    }

    private var displayName: String {
        if let name = persistedName, !name.isEmpty { return name }
        return truncatedPubkey
    }

    private var truncatedPubkey: String {
        guard clientPubkey.count > 12 else { return clientPubkey }
        return String(clientPubkey.prefix(8)) + "…" + String(clientPubkey.suffix(4))
    }
}
