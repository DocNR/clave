import SwiftUI

struct ActivityDetailView: View {
    let entry: ActivityEntry

    private let knownKinds: [Int: String] = [
        0: "Profile Metadata",
        1: "Short Note",
        3: "Contact List",
        4: "Encrypted DM (NIP-04)",
        5: "Deletion",
        6: "Repost",
        7: "Reaction",
        1984: "Report",
        9734: "Zap Request",
        9735: "Zap Receipt",
        10002: "Relay List",
        22242: "Relay Auth",
        30023: "Long-form Article",
        30078: "App-specific Data"
    ]

    var body: some View {
        List {
            Section("Request") {
                row("Method", value: entry.method)

                if let kind = entry.eventKind {
                    row("Event Kind", value: "Kind \(kind)")
                    if let label = knownKinds[kind] {
                        row("Kind Name", value: label)
                    }
                }

                row("Status", value: entry.status.capitalized)

                if let error = entry.errorMessage, !error.isEmpty {
                    row("Detail", value: error)
                }
            }

            Section("Client") {
                HStack {
                    Text("Pubkey")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(entry.clientPubkey)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button {
                    UIPasteboard.general.string = entry.clientPubkey
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Label("Copy Pubkey", systemImage: "doc.on.doc")
                }
            }

            Section("Timing") {
                row("Date", value: formattedDate)
                row("Time", value: formattedTime)
                row("Relative", value: relativeTime)
            }
        }
        .navigationTitle("Activity Detail")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: Date(timeIntervalSince1970: entry.timestamp))
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: Date(timeIntervalSince1970: entry.timestamp))
    }

    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: Date(timeIntervalSince1970: entry.timestamp), relativeTo: Date())
    }
}
