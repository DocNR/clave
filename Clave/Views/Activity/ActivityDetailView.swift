import SwiftUI

struct ActivityDetailView: View {
    let entry: ActivityEntry

    /// Kinds njump.me renders meaningfully. Used to gate the "Open on njump.me"
    /// button — for kinds outside this set (e.g., kind:22242 relay auth, DMs)
    /// the button would just render JSON or 404, so we hide it.
    private static let njumpRenderableKinds: Set<Int> = [
        0, 1, 3, 6, 7, 1985, 9734, 9735, 30023, 30311
    ]

    private let knownKinds: [Int: String] = [
        0: "Profile Metadata",
        1: "Short Note",
        3: "Contact List",
        4: "Encrypted DM (NIP-04)",
        5: "Deletion",
        6: "Repost",
        7: "Reaction",
        14: "Sealed DM",
        1059: "Gift Wrap",
        1984: "Report",
        1985: "Label",
        9734: "Zap Request",
        9735: "Zap Receipt",
        10002: "Relay List",
        22242: "Relay Auth",
        30023: "Long-form Article",
        30078: "App-specific Data",
        30311: "Live Event"
    ]

    var body: some View {
        List {
            requestSection
            if entry.signedEventId != nil || entry.signedSummary != nil {
                signedEventSection
            }
            clientSection
            timingSection
        }
        .navigationTitle("Activity Detail")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Request

    private var requestSection: some View {
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
    }

    // MARK: - Signed Event

    private var signedEventSection: some View {
        Section("Signed Event") {
            if let summary = entry.signedSummary {
                Text(summary)
                    .font(.subheadline)
                    .textSelection(.enabled)
            }

            if let eventId = entry.signedEventId {
                HStack {
                    Text("Event ID")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(eventId)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Button {
                    UIPasteboard.general.string = eventId
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Label("Copy Event ID", systemImage: "doc.on.doc")
                }

                if shouldShowNjumpLink, let url = njumpURL(for: eventId) {
                    Link(destination: url) {
                        Label("Open on njump.me", systemImage: "safari")
                    }
                }
            }
        }
    }

    private var shouldShowNjumpLink: Bool {
        guard let kind = entry.eventKind else { return false }
        return Self.njumpRenderableKinds.contains(kind)
    }

    private func njumpURL(for eventId: String) -> URL? {
        let connection = SharedStorage.getConnectedClients().first { $0.pubkey == entry.clientPubkey }
        let relays = connection?.relayUrls ?? []
        let bech32: String
        if relays.isEmpty {
            guard let note = try? Nip19.encodeNote(eventId: eventId) else { return nil }
            bech32 = note
        } else {
            guard let nevent = try? Nip19.encodeNevent(
                eventId: eventId,
                relays: relays,
                kind: entry.eventKind
            ) else {
                // Fall back to plain note if nevent encoding fails for any reason
                return (try? Nip19.encodeNote(eventId: eventId)).flatMap { URL(string: "https://njump.me/\($0)") }
            }
            bech32 = nevent
        }
        return URL(string: "https://njump.me/\(bech32)")
    }

    // MARK: - Client

    private var clientSection: some View {
        Section("Client") {
            if let name = clientName, !name.isEmpty {
                row("Connection", value: name)
            }

            HStack {
                Text("Pubkey")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(entry.clientPubkey)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Button {
                UIPasteboard.general.string = entry.clientPubkey
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Label("Copy Pubkey", systemImage: "doc.on.doc")
            }
        }
    }

    private var clientName: String? {
        SharedStorage.getClientPermissions(for: entry.clientPubkey)?.name
    }

    // MARK: - Timing

    private var timingSection: some View {
        Section("Timing") {
            row("Date", value: formattedDate)
            row("Time", value: formattedTime)
            row("Relative", value: relativeTime)
        }
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
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
