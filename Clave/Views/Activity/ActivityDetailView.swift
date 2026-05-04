import SwiftUI

struct ActivityDetailView: View {
    let entry: ActivityEntry

    @State private var showConnectionInfo = false

    /// Kinds njump.me renders meaningfully. Used to gate the "Open on njump.me"
    /// button — for kinds outside this set (e.g., kind:22242 relay auth, DMs)
    /// the button would just render JSON or 404, so we hide it.
    private static let njumpRenderableKinds: Set<Int> = [
        0, 1, 3, 6, 7, 1985, 9734, 9735, 30023, 30311
    ]

    /// Wrapper kinds where the user-meaningful target is the *referenced*
    /// event (`signedReferencedEventId`), not the wrapper itself. njump-ing
    /// to a "❤" reaction is useless; njump-ing to the reacted-to note is
    /// what the user wants. For these kinds the button label changes too.
    private static let wrapperKinds: Set<Int> = [6, 7, 9734, 9735]

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
            if hasSignedEvent {
                signedEventSection
            }
            connectionSection
            whenSection
            if showStatusSection {
                statusSection
            }
        }
        .navigationTitle("Activity Detail")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showConnectionInfo) {
            if let perms = permissions {
                ConnectionInfoSheet(perms: perms)
            }
        }
    }

    // MARK: - Signed Event

    private var hasSignedEvent: Bool {
        entry.signedEventId != nil || entry.signedSummary != nil
    }

    private var signedEventSection: some View {
        Section("Signed Event") {
            if let summary = entry.signedSummary {
                Text(summary)
                    .font(.subheadline)
                    .textSelection(.enabled)
            }

            if let kind = entry.eventKind {
                row("Kind", value: kindLabel(for: kind))
            }

            if let eventId = entry.signedEventId {
                copyableEventIdRow(label: "Event ID", value: eventId)
            }

            if let referenced = entry.signedReferencedEventId {
                copyableEventIdRow(label: "Referenced", value: referenced)
            }

            njumpButton
        }
    }

    /// Single row that shows a truncated event id (visually) but copies the
    /// full hex on tap with a haptic. Replaces the prior pair of separate
    /// "Event ID" + "Copy Event ID" rows — truncated hex on its own isn't
    /// useful, the row may as well also be the copy affordance.
    private func copyableEventIdRow(label: String, value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack {
                Text(label)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(truncatedHex(value))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    /// Build the "Open on njump.me" button if we have a meaningful target.
    /// For wrapper kinds (reaction/repost/zap), the target is the referenced
    /// event (so njump renders the reacted-to note, not the bare "❤").
    /// For other renderable kinds, the target is the user's own signed event.
    @ViewBuilder
    private var njumpButton: some View {
        if let kind = entry.eventKind, Self.njumpRenderableKinds.contains(kind) {
            let isWrapper = Self.wrapperKinds.contains(kind)
            // For wrapper kinds, the wrapper itself isn't useful on njump;
            // require a referenced id and skip the button if absent.
            let targetId: String? = isWrapper ? entry.signedReferencedEventId : entry.signedEventId
            let label = isWrapper ? "Open referenced event on njump.me" : "Open on njump.me"
            if let id = targetId, let url = njumpURL(for: id, kindHint: isWrapper ? nil : kind) {
                Link(destination: url) {
                    Label(label, systemImage: "safari")
                }
            }
        }
    }

    /// `kindHint` is the kind to embed in the nevent TLV. For wrapper kinds
    /// we pass nil because we don't know the referenced event's kind from
    /// the activity log alone (could be a kind:1 note, kind:30023 article, etc.).
    private func njumpURL(for eventId: String, kindHint: Int?) -> URL? {
        // Task 7: scope by entry's signer (Task 3 field), with current
        // account fallback for legacy entries.
        let entrySigner = entry.signerPubkeyHex.isEmpty
            ? (SharedConstants.sharedDefaults.string(forKey: SharedConstants.currentSignerPubkeyHexKey) ?? "")
            : entry.signerPubkeyHex
        let connection = SharedStorage.getConnectedClients(for: entrySigner).first { $0.pubkey == entry.clientPubkey }
        let relays = connection?.relayUrls ?? []
        let bech32: String
        if relays.isEmpty {
            guard let note = try? Nip19.encodeNote(eventId: eventId) else { return nil }
            bech32 = note
        } else {
            guard let nevent = try? Nip19.encodeNevent(
                eventId: eventId,
                relays: relays,
                kind: kindHint
            ) else {
                return (try? Nip19.encodeNote(eventId: eventId)).flatMap { URL(string: "https://njump.me/\($0)") }
            }
            bech32 = nevent
        }
        return URL(string: "https://njump.me/\(bech32)")
    }

    // MARK: - Connection

    /// Tappable row that opens `ConnectionInfoSheet` for this client.
    /// That sheet already shows hex pubkey, npub form, copy buttons, paired
    /// relays, etc., so duplicating any of that here would be dead weight.
    private var connectionSection: some View {
        Section("Connection") {
            Button {
                showConnectionInfo = true
            } label: {
                HStack {
                    Text(connectionLabel)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .disabled(permissions == nil)
        }
    }

    private var permissions: ClientPermissions? {
        // Task 7: scope by (entry's signer, client) — same fallback
        // pattern as njumpURL above.
        let entrySigner = entry.signerPubkeyHex.isEmpty
            ? (SharedConstants.sharedDefaults.string(forKey: SharedConstants.currentSignerPubkeyHexKey) ?? "")
            : entry.signerPubkeyHex
        return SharedStorage.getClientPermissions(signer: entrySigner, client: entry.clientPubkey)
    }

    private var connectionLabel: String {
        if let name = permissions?.name, !name.isEmpty {
            return name
        }
        return truncatedHex(entry.clientPubkey)
    }

    // MARK: - When

    private var whenSection: some View {
        Section("When") {
            Text(humanizedTimestamp)
                .textSelection(.enabled)
        }
    }

    /// Calendar-aware single-line timestamp. Long-press on the row copies it
    /// (via `.textSelection(.enabled)`); power users can grab the exact ISO
    /// timestamp if they need it.
    private var humanizedTimestamp: String {
        let date = Date(timeIntervalSince1970: entry.timestamp)
        let now = Date()
        let calendar = Calendar.current

        // Within the last hour: relative ("5 minutes ago")
        if let secondsAgo = calendar.dateComponents([.second], from: date, to: now).second,
           secondsAgo >= 0, secondsAgo < 3600 {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter.localizedString(for: date, relativeTo: now)
        }

        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        let timeString = timeFormatter.string(from: date)

        if calendar.isDateInToday(date) {
            return "Today at \(timeString)"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday at \(timeString)"
        }

        // Within the last 7 days: short weekday ("Mon at 11:42 AM")
        if let daysAgo = calendar.dateComponents([.day], from: date, to: now).day,
           daysAgo >= 0, daysAgo < 7 {
            let weekdayFormatter = DateFormatter()
            weekdayFormatter.dateFormat = "EEE"
            return "\(weekdayFormatter.string(from: date)) at \(timeString)"
        }

        // Older: "Apr 28 at 9:30 AM"
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "MMM d"
        return "\(dayFormatter.string(from: date)) at \(timeString)"
    }

    // MARK: - Status (conditional)

    /// Only shown when there's something interesting to report:
    /// - non-"signed" status (pending, blocked, error)
    /// - a non-empty error message
    /// - non-sign_event method (connect, etc.) — for sign_event the Signed
    ///   Event section already covers it
    private var showStatusSection: Bool {
        if entry.status != "signed" { return true }
        if let error = entry.errorMessage, !error.isEmpty { return true }
        if entry.method != "sign_event" { return true }
        return false
    }

    private var statusSection: some View {
        Section("Status") {
            if entry.method != "sign_event" {
                row("Method", value: entry.method)
            }
            if entry.status != "signed" {
                row("Status", value: entry.status.capitalized)
            }
            if let error = entry.errorMessage, !error.isEmpty, entry.status != "signed" {
                row("Error", value: error)
            }
        }
    }

    // MARK: - Helpers

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

    private func kindLabel(for kind: Int) -> String {
        if let name = knownKinds[kind] {
            return "Kind \(kind) (\(name))"
        }
        return "Kind \(kind)"
    }

    private func truncatedHex(_ hex: String) -> String {
        guard hex.count > 12 else { return hex }
        return String(hex.prefix(8)) + "…" + String(hex.suffix(4))
    }
}
