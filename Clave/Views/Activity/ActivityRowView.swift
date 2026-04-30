import SwiftUI

struct ActivityRowView: View {
    let entry: ActivityEntry

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

                HStack(spacing: 4) {
                    Text(clientLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text("·")
                        .foregroundStyle(.tertiary)

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
        if let name = SharedStorage.getClientPermissions(for: entry.clientPubkey)?.name,
           !name.isEmpty {
            return name
        }
        return truncatedPubkey(entry.clientPubkey)
    }
}
