import SwiftUI

/// Compact row UI for a single pending request, used inside `InboxView`'s
/// list. Mirrors the layout of HomeView's connected-clients rows
/// (avatar + name + subtitle + trailing time) for visual consistency.
/// Swipe actions and tap-to-detail navigation are wired up by the parent
/// list, not here — this view is presentation-only.
struct PendingRequestRow: View {
    let request: PendingRequest
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(
                pubkeyHex: request.clientPubkey,
                name: clientName,
                size: 36
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(displayClientName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(actionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if appState.accounts.count > 1 {
                    Text("as @\(signerLabel)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(relativeTime)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// Resolved name on the persisted permissions row, if any. Used to
    /// drive AvatarView's initials when the row exists. Returns nil for
    /// unpaired clients (rare — pending requests should always be from
    /// a paired client) so AvatarView falls back to pubkey-derived
    /// initials.
    private var clientName: String? {
        SharedStorage.getClientPermissions(for: request.clientPubkey)?.name
    }

    /// Display name shown in the row title. Falls back to a truncated
    /// pubkey when no permissions row exists yet.
    private var displayClientName: String {
        if let n = clientName, !n.isEmpty { return n }
        return truncatedPubkey(request.clientPubkey)
    }

    private var actionSummary: String {
        switch request.method {
        case "sign_event":
            if let kind = request.eventKind {
                return "Wants to sign \(KnownKinds.label(for: kind))"
            }
            return "Wants to sign an event"
        case "nip04_encrypt", "nip44_encrypt":
            return "Wants to encrypt a message"
        case "nip04_decrypt", "nip44_decrypt":
            return "Wants to decrypt a message"
        default:
            return request.method
        }
    }

    private var signerLabel: String {
        let pubkey = request.signerPubkeyHex.isEmpty
            ? appState.signerPubkeyHex
            : request.signerPubkeyHex
        return appState.accounts.first(where: { $0.pubkeyHex == pubkey })?.displayLabel
            ?? String(pubkey.prefix(8))
    }

    private var relativeTime: String {
        let date = Date(timeIntervalSince1970: request.timestamp)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func truncatedPubkey(_ hex: String) -> String {
        guard hex.count > 12 else { return hex }
        return String(hex.prefix(8)) + "…" + String(hex.suffix(4))
    }
}
