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
/// Grant scope selected by the user in the v3 approval prompt. Drives
/// what (if anything) gets written to `ClientPermissions.v3KindScopePermissions`
/// on approve.
private enum V3GrantChoice: Hashable {
    /// Approve this single call only — no grant persisted.
    case once
    /// Persist `KindScopeKey(kind, nil)` — auto-approve future calls for
    /// the same kind regardless of scope.
    case alwaysKind
    /// Persist `KindScopeKey(kind, scope)` — auto-approve only when the
    /// caller supplies this exact scope under this kind (tighter grant).
    case alwaysKindScope
}

struct PendingRequestDetailView: View {
    let request: PendingRequest
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var alwaysAllow = false
    @State private var v3GrantChoice: V3GrantChoice = .once
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
            } else if isV3Method, request.v3Kind != nil {
                v3GrantSection
            }
            if isLegacyV2Method {
                legacyV2FootnoteSection
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
            if let v3Kind = request.v3Kind {
                v3KindRow(kind: v3Kind)
                if let scope = request.v3Scope, !scope.isEmpty {
                    v3ScopeRow(scope: scope)
                }
                // tierWarningBanner is @ViewBuilder; for `.normal` it returns
                // EmptyView() which renders nothing. No conditional binding.
                tierWarningBanner(forKind: Int(v3Kind))
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

    @ViewBuilder
    private func v3KindRow(kind: UInt32) -> some View {
        let kindInt = Int(kind)
        if KnownKinds.names[kindInt] != nil {
            LabeledContent("Kind", value: KnownKinds.label(for: kindInt))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent("Kind", value: "kind:\(kindInt)")
                Text("Unknown — Clave doesn't recognize this type. Approve only if you trust this app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func v3ScopeRow(scope: String) -> some View {
        let display = scope.count > 80 ? String(scope.prefix(77)) + "…" : scope
        VStack(alignment: .leading, spacing: 2) {
            Text("Scope")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("\u{201C}\(display)\u{201D}")
                .font(.system(.subheadline, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func tierWarningBanner(forKind kind: Int) -> some View {
        switch KnownKinds.sensitivityTier(for: kind) {
        case .tierS:
            Label {
                Text("This data is highly sensitive. Only approve if you initiated this action right now in \(displayClientName).")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            } icon: {
                Image(systemName: "lock.shield.fill")
            }
            .foregroundStyle(.red)
        case .tierA:
            Label {
                Text("This is a private message or wallet operation. Approve only if you recognize this action.")
                    .font(.subheadline)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(.orange)
        case .tierB:
            Label {
                Text("This may be private list content. Review the kind and scope above before approving.")
                    .font(.subheadline)
            } icon: {
                Image(systemName: "info.circle.fill")
            }
            .foregroundStyle(.secondary)
        case .normal:
            EmptyView()
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

    /// v3-specific grant chooser. Tier S kinds get an info-only message
    /// (no always-allow) per the spec's sensitivity-tier policy; all
    /// other tiers get a Picker with Once / kind-wildcard / kind+scope
    /// options. The kind+scope option only appears when the request
    /// actually carries a non-empty scope.
    @ViewBuilder
    private var v3GrantSection: some View {
        if let kind = request.v3Kind {
            let kindInt = Int(kind)
            let tier = KnownKinds.sensitivityTier(for: kindInt)
            if tier == .tierS {
                Section {
                    Label {
                        Text("Always allow is unavailable for sensitive financial data. Approve once, or deny.")
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "lock.fill")
                    }
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Grant permission")
                }
            } else {
                let hasScope = (request.v3Scope?.isEmpty == false)
                Section {
                    Picker("Grant permission", selection: $v3GrantChoice) {
                        Text("Once").tag(V3GrantChoice.once)
                        Text(alwaysKindPickerLabel(kind: kindInt))
                            .tag(V3GrantChoice.alwaysKind)
                        if hasScope, let scope = request.v3Scope {
                            Text("Always allow this kind + scope (\u{201C}\(scopePickerSummary(scope))\u{201D})")
                                .tag(V3GrantChoice.alwaysKindScope)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .disabled(processing)
                } header: {
                    Text("Grant permission")
                } footer: {
                    Text(v3GrantFooter(kindInt: kindInt))
                }
            }
        }
    }

    /// Small caption shown below v2 prompts to teach users why v3-aware
    /// prompts (when they exist) are richer. Indirect upgrade pressure
    /// on client authors; renders only for v2 encrypt/decrypt methods.
    private var legacyV2FootnoteSection: some View {
        Section {
            EmptyView()
        } footer: {
            Text("NIP-44 v2 — Clave cannot tell what this data represents. Upgrade your app for clearer prompts.")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
            // v3 grant persistence — mirrors the sign_event override path
            // above. Inline (rather than an AppState helper) because this is
            // the sole writer and the data shape is local to this view's
            // V3GrantChoice state. Tier S short-circuits at the UI level
            // (no .alwaysKind / .alwaysKindScope branches are reachable
            // because the picker isn't rendered).
            if isV3Method, v3GrantChoice != .once, let kind = request.v3Kind {
                let signer = request.signerPubkeyHex.isEmpty
                    ? appState.signerPubkeyHex
                    : request.signerPubkeyHex
                if var perms = SharedStorage.getClientPermissions(signer: signer, client: request.clientPubkey) {
                    let scopeKey: String? = (v3GrantChoice == .alwaysKindScope) ? request.v3Scope : nil
                    var grants = perms.v3KindScopePermissions[request.method, default: []]
                    grants.insert(KindScopeKey(kind: kind, scope: scopeKey))
                    perms.v3KindScopePermissions[request.method] = grants
                    SharedStorage.saveClientPermissions(perms)
                }
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
        case "nip44v3_encrypt":  return "Encrypt (NIP-44 v3)"
        case "nip44v3_decrypt":  return "Decrypt (NIP-44 v3)"
        case "connect":          return "Connect"
        default:                 return request.method
        }
    }

    private var isV3Method: Bool {
        request.method == "nip44v3_encrypt" || request.method == "nip44v3_decrypt"
    }

    /// True for v2 encrypt/decrypt methods that lack the kind+scope
    /// binding that makes v3 prompts informative. Drives the footnote
    /// section that teaches users about the v3 upgrade path.
    private var isLegacyV2Method: Bool {
        switch request.method {
        case "nip04_encrypt", "nip04_decrypt",
             "nip44_encrypt", "nip44_decrypt":
            return true
        default:
            return false
        }
    }

    private func alwaysKindPickerLabel(kind: Int) -> String {
        if KnownKinds.names[kind] != nil {
            return "Always allow \(KnownKinds.label(for: kind))"
        }
        return "Always allow kind:\(kind)"
    }

    private func scopePickerSummary(_ scope: String) -> String {
        scope.count > 32 ? String(scope.prefix(29)) + "…" : scope
    }

    private func v3GrantFooter(kindInt: Int) -> String {
        switch v3GrantChoice {
        case .once:
            return "This request only — no future calls will be auto-approved."
        case .alwaysKind:
            return "Future \(actionLabel.lowercased()) calls for this kind from \(displayClientName) will be auto-approved. Revoke in Settings → \(displayClientName)."
        case .alwaysKindScope:
            return "Future \(actionLabel.lowercased()) calls for this exact kind + scope from \(displayClientName) will be auto-approved. Revoke in Settings → \(displayClientName)."
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
