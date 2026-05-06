import SwiftUI

/// Full-context detail view for a single pending request, pushed from
/// `InboxView` when the user taps a row. Shows the client identity,
/// the action being requested with kind + content preview, the signing
/// account, the trust level context, an optional "Always allow this
/// kind from <client>" toggle (deliberate two-step path that addresses
/// backlog D.6.1 — single-tap "Always Allow" was too easy to misfire
/// from the old orange card), and the raw event JSON behind a
/// disclosure for power users. Approve / Deny live at the bottom in
/// their own section.
struct PendingRequestDetailView: View {
    let request: PendingRequest
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var alwaysAllow = false
    @State private var processing = false
    @State private var errorMessage: String?
    @State private var showRawJSON = false

    var body: some View {
        Form {
            clientSection
            requestSection
            if appState.accounts.count > 1 { accountSection }
            trustSection
            if request.method == "sign_event", request.eventKind != nil {
                alwaysAllowSection
            }
            rawJSONSection
            actionsSection
        }
        .navigationTitle("Pending Request")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Approval failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        ), presenting: errorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
    }

    // MARK: - Sections

    private var clientSection: some View {
        Section {
            ClientIdentityHeader(clientPubkey: request.clientPubkey)
        }
    }

    private var requestSection: some View {
        Section("Wants to") {
            LabeledContent("Action", value: actionLabel)
            if let kind = request.eventKind {
                LabeledContent("Kind", value: KnownKinds.label(for: kind))
            }
            if let preview = contentPreview {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preview")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(preview)
                        .font(.subheadline)
                        .lineLimit(6)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var accountSection: some View {
        Section("On account") {
            AccountStripeRow(signerPubkeyHex: request.signerPubkeyHex)
        }
    }

    private var trustSection: some View {
        Section("Client trust") {
            Text(trustExplanation)
                .font(.subheadline)
        }
    }

    private var alwaysAllowSection: some View {
        Section {
            Toggle(isOn: $alwaysAllow) {
                if let kind = request.eventKind {
                    Text("Always allow \(KnownKinds.label(for: kind))")
                } else {
                    Text("Always allow this kind")
                }
            }
            .disabled(processing)
        } footer: {
            if let kind = request.eventKind {
                Text("Future requests for \(KnownKinds.label(for: kind)) from \(displayClientName) will be auto-signed. You can revoke in Settings → \(displayClientName).")
            }
        }
    }

    private var rawJSONSection: some View {
        Section {
            RawEventDisclosure(
                title: "View raw request",
                json: request.requestEventJSON,
                isExpanded: $showRawJSON
            )
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                approve()
            } label: {
                HStack {
                    if processing {
                        ProgressView()
                            .controlSize(.small)
                        Text("Signing…")
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Approve")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(processing)
            .foregroundStyle(processing ? Color.secondary : Color.green)

            Button(role: .destructive) {
                appState.denyPendingRequest(request)
                dismiss()
            } label: {
                HStack {
                    Image(systemName: "xmark.circle.fill")
                    Text("Deny")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(processing)
        }
    }

    // MARK: - Approve action

    private func approve() {
        processing = true
        Task {
            // Persist the kind override BEFORE approving so a successful
            // approval correctly transitions future requests for the same
            // kind to auto-sign. If approval fails the override still
            // applies — fine, the user opted in deliberately.
            if alwaysAllow, let kind = request.eventKind {
                let signer = request.signerPubkeyHex.isEmpty
                    ? appState.signerPubkeyHex
                    : request.signerPubkeyHex
                appState.setKindOverride(
                    signer: signer,
                    client: request.clientPubkey,
                    kind: kind,
                    allowed: true
                )
            }
            let outcome = await appState.approvePendingRequest(request)
            processing = false
            switch outcome {
            case .signed:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            case .failedKeepingPending(let reason):
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                errorMessage = reason
            case .failedAndRemoved(let reason):
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                errorMessage = reason
            }
        }
    }

    // MARK: - Computed display

    private var persistedClientName: String? {
        SharedStorage.getClientPermissions(for: request.clientPubkey)?.name
    }

    private var displayClientName: String {
        if let n = persistedClientName, !n.isEmpty { return n }
        return truncatedPubkey(request.clientPubkey)
    }

    private var actionLabel: String {
        switch request.method {
        case "sign_event":       return "Sign event"
        case "nip04_encrypt":    return "Encrypt (NIP-04)"
        case "nip04_decrypt":    return "Decrypt (NIP-04)"
        case "nip44_encrypt":    return "Encrypt (NIP-44)"
        case "nip44_decrypt":    return "Decrypt (NIP-44)"
        case "connect":          return "Connect"
        default:                 return request.method
        }
    }

    /// Lightweight content extraction. Decodes the relay event from
    /// `requestEventJSON`, looks at the encrypted `content` field — but
    /// we can't decrypt without the nsec, so the preview is method-aware
    /// based on what's safe to show without crypto. For sign_event we
    /// show the wrapper kind:24133 size + indicate the inner kind. For
    /// encryption methods we show approximate ciphertext size.
    private var contentPreview: String? {
        guard let data = request.requestEventJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = dict["content"] as? String else {
            return nil
        }
        let bytes = content.utf8.count
        switch request.method {
        case "sign_event":
            return "Encrypted request, \(bytes) bytes — full content shown after approval."
        case "nip04_encrypt", "nip44_encrypt":
            return "Encrypted plaintext, \(bytes) bytes."
        case "nip04_decrypt", "nip44_decrypt":
            return "Encrypted ciphertext, \(bytes) bytes."
        default:
            return nil
        }
    }

    private var trustExplanation: String {
        let signer = request.signerPubkeyHex.isEmpty
            ? appState.signerPubkeyHex
            : request.signerPubkeyHex
        guard let perms = SharedStorage.getClientPermissions(signer: signer, client: request.clientPubkey) else {
            return "This client isn't paired with this account. Approving will sign once but won't grant ongoing access."
        }
        switch perms.trustLevel {
        case .full:
            return "Full trust — all requests would auto-sign, but this kind is currently overridden to require approval."
        case .medium:
            return "Medium trust — requests for sensitive kinds (profile, contacts, etc.) require your approval."
        case .low:
            return "Low trust — every request requires your approval."
        }
    }

    private func truncatedPubkey(_ hex: String) -> String {
        guard hex.count > 12 else { return hex }
        return String(hex.prefix(8)) + "…" + String(hex.suffix(4))
    }
}
