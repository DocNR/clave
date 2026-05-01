import SwiftUI

struct ActivityRowView: View {
    let entry: ActivityEntry
    /// When false, omits the pet-name segment from the subtitle. Used by
    /// `ClientDetailView`'s "Recent Activity" section where the connection
    /// is already implied by the surrounding nav title.
    var showsClientName: Bool = true

    var body: some View {
        HStack(spacing: 10) {
            statusIcon

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.method)
                        .font(.subheadline.bold())

                    if let kind = entry.eventKind {
                        Text("Kind \(kind)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.systemGray5), in: Capsule())
                    }
                }

                if let summary = entry.signedSummary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 4) {
                    if showsClientName {
                        Text(clientLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text("·")
                            .foregroundStyle(.tertiary)
                    }

                    Text(relativeTime)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var statusIcon: some View {
        Group {
            switch entry.status {
            case "signed":
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case "pending":
                Image(systemName: "clock.circle.fill")
                    .foregroundStyle(.orange)
            case "blocked":
                Image(systemName: "slash.circle.fill")
                    .foregroundStyle(.red)
            default:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.title3)
    }

    private var relativeTime: String {
        let date = Date(timeIntervalSince1970: entry.timestamp)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func truncatedPubkey(_ hex: String) -> String {
        guard hex.count > 12 else { return hex }
        return String(hex.prefix(8)) + "..." + String(hex.suffix(4))
    }

    private var clientLabel: String {
        // Task 7: scope by entry's signer. Falls back to current account
        // for legacy entries with empty signer. Without scoping, the
        // same client paired with two accounts could surface the wrong
        // account's pet-name in the activity row.
        let entrySigner = entry.signerPubkeyHex.isEmpty
            ? (SharedConstants.sharedDefaults.string(forKey: SharedConstants.currentSignerPubkeyHexKey) ?? "")
            : entry.signerPubkeyHex
        if let name = SharedStorage.getClientPermissions(signer: entrySigner, client: entry.clientPubkey)?.name,
           !name.isEmpty {
            return name
        }
        return truncatedPubkey(entry.clientPubkey)
    }
}
