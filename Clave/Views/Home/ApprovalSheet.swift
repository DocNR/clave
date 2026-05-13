import SwiftUI
import UIKit

struct ApprovalSheet: View {
    let parsedURI: NostrConnectParser.ParsedURI
    /// Account(s) the user picked in ConnectAccountPicker. Phase 2 multi-account:
    /// may contain 2+ pubkeys when the client requested `accounts=multi` and the
    /// user selected multiple. Single-mode (count == 1) preserves Phase 1 UX.
    /// May be empty in degenerate paths; downstream guards treat empty as no-op.
    let boundAccountPubkeys: [String]
    /// Called when the handshake completes (success, partial, or all-failure).
    /// Phase 2 contract change (Task 10): sheet now runs the handshake itself
    /// so progress state can live where it's rendered. Parent decides dismiss
    /// based on result.{isAllSuccess, isAllFailure, isPartialFailure}.
    let onCompletion: (HandshakeResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var selectedTrust: TrustLevel
    @State private var kindOverrides: [Int: Bool] = [:]
    @State private var showPermissions = false
    @State private var showConnectionCapAlert = false

    // Progress state (Task 10) — populated while handleNostrConnect runs.
    // Phase 1 single-mode renders only `isConnecting`; multi-mode renders
    // the per-row overlay built from progressIndex/progressTotal/
    // currentlyPairing/succeededSoFar.
    @State private var isConnecting: Bool = false
    @State private var progressIndex: Int = 0
    @State private var progressTotal: Int = 0
    @State private var currentlyPairing: String? = nil
    @State private var succeededSoFar: Set<String> = []
    /// Latched once the loop finishes (success or partial). Keeps the
    /// non-action UI in place so the user can't re-tap Approve while the
    /// parent decides whether to dismiss (all-success / all-failure) or
    /// hand control to the partial-failure result view (Task 11).
    @State private var handshakeCompleted: Bool = false

    private let protectedKinds: Set<Int> = SharedStorage.getProtectedKinds()

    init(parsedURI: NostrConnectParser.ParsedURI,
         boundAccountPubkeys: [String] = [],
         onCompletion: @escaping (HandshakeResult) -> Void) {
        self.parsedURI = parsedURI
        self.boundAccountPubkeys = boundAccountPubkeys
        self.onCompletion = onCompletion
        _selectedTrust = State(initialValue: parsedURI.suggestedTrustLevel)
    }

    private var isMulti: Bool { boundAccountPubkeys.count > 1 }

    /// Primary signer for single-mode rendering + cap check. Falls back to the
    /// current account when the bound list is empty (legacy/degenerate path).
    private var primarySignerPubkey: String {
        boundAccountPubkeys.first ?? appState.signerPubkeyHex
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    headerBlock
                        .padding(.horizontal)
                        .padding(.top, 12)
                    clientHeader
                    if isConnecting {
                        progressBlock
                    } else if handshakeCompleted {
                        // Latched post-loop. For all-success / all-failure
                        // the parent's onCompletion dismisses the sheet
                        // before this branch is visible for more than a
                        // frame. For partial-failure the sheet stays here
                        // until Task 11 replaces this placeholder with the
                        // per-row result view + Done button.
                        completedPlaceholder
                    } else {
                        trustLevelCards
                        permissionsSection
                        actionButtons
                    }
                }
                .padding()
            }
            .navigationTitle("Approve Connection")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isConnecting)
            .alert("Connection limit reached", isPresented: $showConnectionCapAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(AccountError.connectionCapReached.errorDescription ?? "")
            }
        }
        .snapshotProtected()
    }

    // MARK: - Signing-As Header (single / multi)

    @ViewBuilder
    private var headerBlock: some View {
        if isMulti {
            multiHeader
        } else {
            singleHeader
        }
    }

    private var singleHeader: some View {
        SigningAsHeader(signerPubkeyHex: primarySignerPubkey)
    }

    private var multiHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(clientDisplayName) is requesting to sign for \(boundAccountPubkeys.count) accounts")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            selectedAccountsInlineList
        }
    }

    private var selectedAccountsInlineList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(boundAccountPubkeys, id: \.self) { pubkey in
                    accountChip(pubkey: pubkey)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func accountChip(pubkey: String) -> some View {
        let account = appState.accounts.first(where: { $0.pubkeyHex == pubkey })
        let label = account?.displayLabel ?? String(pubkey.prefix(8))
        return HStack(spacing: 6) {
            AvatarView(pubkeyHex: pubkey, name: account?.displayLabel, size: 28)
            Text(label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.tertiarySystemGroupedBackground), in: Capsule())
    }

    private var clientDisplayName: String {
        parsedURI.name ?? "This app"
    }

    // MARK: - Client Identity Header

    private var clientHeader: some View {
        VStack(spacing: 12) {
            if let imageURLString = parsedURI.imageURL,
               let url = URL(string: imageURLString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(Circle())
                    default:
                        AvatarView(pubkeyHex: parsedURI.clientPubkey, name: parsedURI.name, size: 64)
                    }
                }
            } else {
                AvatarView(pubkeyHex: parsedURI.clientPubkey, name: parsedURI.name, size: 64)
            }

            Text(parsedURI.name ?? truncatedPubkey)
                .font(.title3.weight(.semibold))

            if let url = parsedURI.url {
                Text(url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: - Trust Level Cards

    private var trustLevelCards: some View {
        VStack(spacing: 12) {
            trustCard(
                level: .full,
                title: "Full Trust",
                subtitle: "Auto-sign all requests",
                color: .green
            )
            trustCard(
                level: .medium,
                title: "Medium Trust",
                subtitle: "Ask for sensitive operations",
                color: .blue
            )
            trustCard(
                level: .low,
                title: "Low Trust",
                subtitle: "Ask for every request",
                color: .orange
            )
        }
    }

    private func trustCard(level: TrustLevel, title: String, subtitle: String, color: Color) -> some View {
        let isSelected = selectedTrust == level
        return Button {
            selectedTrust = level
            kindOverrides = [:]
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(color)
                        .font(.title3)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? color.opacity(0.1) : Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? color : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Permissions Section

    private var permissionsSection: some View {
        DisclosureGroup("View permissions", isExpanded: $showPermissions) {
            VStack(spacing: 0) {
                ForEach(allKindsSorted, id: \.self) { kind in
                    permissionRow(for: kind)
                    if kind != allKindsSorted.last {
                        Divider()
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private func permissionRow(for kind: Int) -> some View {
        let defaultValue = defaultForTrustLevel(kind)
        let binding = Binding<Bool>(
            get: { kindOverrides[kind] ?? defaultValue },
            set: { newValue in
                if newValue == defaultForTrustLevel(kind) {
                    kindOverrides.removeValue(forKey: kind)
                } else {
                    kindOverrides[kind] = newValue
                }
            }
        )

        return Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Kind \(kind)")
                    .font(.subheadline.weight(.medium))
                if let name = KnownKinds.names[kind] {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.trailing, 4)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 16) {
            Button("Deny") {
                dismiss()
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)

            Button {
                buildAndApprove()
            } label: {
                Text(approveButtonLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
    }

    private var approveButtonLabel: String {
        if isMulti {
            return "Approve \(boundAccountPubkeys.count) accounts"
        } else {
            return "Connect as @\(signingAsDisplayLabel)"
        }
    }

    // MARK: - Progress UI (Task 10)

    /// While the handshake loop runs, the trust/permissions/buttons block is
    /// replaced with a connecting indicator. Single-mode shows a generic
    /// spinner + copy (matches the deleted ConnectTabView overlay); multi-mode
    /// shows per-row state.
    @ViewBuilder
    private var progressBlock: some View {
        if isMulti {
            multiProgressOverlay
        } else {
            singleProgressOverlay
        }
    }

    private var singleProgressOverlay: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            VStack(spacing: 6) {
                Text("Connecting...")
                    .font(.headline)
                Text("Switch back to your client app to finish connecting. Clave keeps running in the background.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 24)
    }

    private var multiProgressOverlay: some View {
        VStack(spacing: 12) {
            // Clamp the displayed counter to `total` — `progressIndex` is
            // 0-based and ticks ahead of completion, so `index + 1` is the
            // human-readable "currently on", capped at total in the final
            // dwell before isConnecting flips off.
            Text("Pairing \(min(progressIndex + 1, max(progressTotal, 1))) of \(progressTotal)…")
                .font(.headline)
                .foregroundStyle(.secondary)
            ForEach(boundAccountPubkeys, id: \.self) { pubkey in
                progressRow(for: pubkey)
            }
        }
        .padding(.vertical, 12)
    }

    /// Empty-but-non-empty placeholder while the parent decides what to do
    /// with the completed result. Task 11 replaces this with the partial-
    /// failure result view (per-row state + retry/done buttons).
    private var completedPlaceholder: some View {
        VStack(spacing: 12) {
            if isMulti {
                ForEach(boundAccountPubkeys, id: \.self) { pubkey in
                    progressRow(for: pubkey)
                }
            } else {
                ProgressView().controlSize(.small)
                Text("Finishing up…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
    }

    private func progressRow(for pubkey: String) -> some View {
        let isCurrent = currentlyPairing == pubkey
        let isDone = succeededSoFar.contains(pubkey)
        let isQueued = !isCurrent && !isDone
        let account = appState.accounts.first(where: { $0.pubkeyHex == pubkey })
        let label = account?.displayLabel ?? String(pubkey.prefix(8))

        return HStack(spacing: 10) {
            ZStack {
                if isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                } else if isCurrent {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "circle.dotted")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
            }
            .frame(width: 24, height: 24)
            AvatarView(pubkeyHex: pubkey, name: account?.displayLabel, size: 28)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(isQueued ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10))
        .opacity(isQueued ? 0.55 : 1.0)
    }

    // MARK: - Helpers

    private var signingAsDisplayLabel: String {
        let pk = primarySignerPubkey
        return appState.accounts.first(where: { $0.pubkeyHex == pk })?.displayLabel
            ?? String(pk.prefix(8))
    }

    private var truncatedPubkey: String {
        let pk = parsedURI.clientPubkey
        if pk.count > 12 {
            return String(pk.prefix(8)) + "..." + String(pk.suffix(4))
        }
        return pk
    }

    private var allKindsSorted: [Int] {
        var kinds = Set<Int>()

        // 1. Parse requested perms for sign_event:N entries
        for perm in parsedURI.requestedPerms {
            if perm.hasPrefix("sign_event:"),
               let kindNum = Int(perm.dropFirst("sign_event:".count)) {
                kinds.insert(kindNum)
            }
        }

        // 2. Add all protected kinds
        kinds.formUnion(protectedKinds)

        // 3. Add common kinds: notes, reposts, reactions
        kinds.formUnion([1, 6, 7])

        return kinds.sorted()
    }

    private func defaultForTrustLevel(_ kind: Int) -> Bool {
        switch selectedTrust {
        case .full:
            return true
        case .medium:
            return !protectedKinds.contains(kind)
        case .low:
            return false
        }
    }

    private func buildAndApprove() {
        // Free-tier cap: 5 paired clients PER ACCOUNT (Task 7 — was
        // global before multi-account, but the cap is conceptually
        // per-account: each account independently maintains its own
        // pairings). Counts SharedStorage.connectedClients scoped to
        // the current signer. Re-pairing an existing client (same
        // pubkey) isn't blocked since no new row is added.
        //
        // Phase 2 multi-account: this sheet only inspects the *first*
        // bound account for the cap check + ClientPermissions template.
        // The per-signer permission row creation happens in
        // runSingleConnect (AppState+NostrConnect.swift), which clones
        // this template via `permissions.with(signerPubkeyHex:)` per
        // iteration so N distinct rows land in SharedStorage — one per
        // (signer_pubkey_i, client_pubkey) composite key (spec §
        // "handleNostrConnect — N-up handshake loop"). The sheet stays
        // single-permission-block per spec §"ApprovalSheet — multi-mode
        // shared permissions"; Task 10/11 add multi-progress/partial-
        // failure UX layered on top.
        let signerForCheck = boundAccountPubkeys.first ?? SharedConstants.sharedDefaults.string(
            forKey: SharedConstants.currentSignerPubkeyHexKey
        ) ?? ""
        let connected = SharedStorage.getConnectedClients(for: signerForCheck)
        let alreadyPaired = connected.contains { $0.pubkey == parsedURI.clientPubkey }
        if !alreadyPaired && connected.count >= Account.maxClientsPerAccount {
            showConnectionCapAlert = true
            return
        }

        let permissions = ClientPermissions(
            pubkey: parsedURI.clientPubkey,
            trustLevel: selectedTrust,
            kindOverrides: kindOverrides,
            methodPermissions: ClientPermissions.defaultMethodPermissions,
            name: parsedURI.name,
            url: parsedURI.url,
            imageURL: parsedURI.imageURL,
            connectedAt: Date().timeIntervalSince1970,
            lastSeen: Date().timeIntervalSince1970,
            requestCount: 0,
            signerPubkeyHex: signerForCheck
        )
        runHandshake(permissions: permissions)
    }

    /// Runs the handshake loop in-sheet so the progress UI has a host.
    /// Wraps the per-pair Task in a UIBackgroundTask so the ~2-3s
    /// connect→ack window survives the user swiping back to their client
    /// app mid-flight (build-62 bg-task pattern, previously lived in
    /// ConnectTabView.submitApproval).
    private func runHandshake(permissions: ClientPermissions) {
        // Seed progress state on the main actor before the Task spawns so
        // the UI swap happens synchronously with the button tap (no flash
        // of action-buttons before the spinner appears).
        let signers = boundAccountPubkeys
        isConnecting = true
        progressTotal = signers.count
        progressIndex = 0
        currentlyPairing = signers.first
        succeededSoFar = []

        Task { @MainActor in
            var bgTaskID: UIBackgroundTaskIdentifier = .invalid
            bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "nostrconnect-pair") {
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                    bgTaskID = .invalid
                }
            }
            do {
                let result = try await appState.handleNostrConnect(
                    parsedURI: parsedURI,
                    signerPubkeys: signers,
                    permissions: permissions,
                    progress: { idx, total, signer in
                        // handleNostrConnect doesn't carry @MainActor — be
                        // explicit about dispatching SwiftUI state writes
                        // back to the main actor regardless of future
                        // isolation changes upstream.
                        //
                        // Speculative-success: when idx advances to k, the
                        // signer at k-1 has just FINISHED (success or
                        // failure — we don't know which until the final
                        // HandshakeResult). We optimistically mark it as
                        // succeeded so the row shows a green checkmark
                        // instead of regressing to the dotted-circle
                        // "queued" state. Mispredicts (rare) are corrected
                        // at loop end when `succeededSoFar = Set(result.
                        // succeeded)`; Task 11's partial-failure view
                        // surfaces the authoritative per-row status.
                        Task { @MainActor in
                            if idx > 0, idx <= signers.count {
                                succeededSoFar.insert(signers[idx - 1])
                            }
                            progressIndex = idx
                            progressTotal = total
                            currentlyPairing = signer
                        }
                    }
                )
                // On the main actor by virtue of Task { @MainActor in ... }.
                succeededSoFar = Set(result.succeeded)
                currentlyPairing = nil
                isConnecting = false
                handshakeCompleted = true
                onCompletion(result)
            } catch {
                // Boundary error (e.g., empty signers) — synthesize an
                // all-failure result so the parent treats it uniformly.
                isConnecting = false
                handshakeCompleted = true
                let failed = signers.map {
                    HandshakeResult.FailedSigner(
                        signerPubkey: $0,
                        errorMessage: error.localizedDescription
                    )
                }
                onCompletion(HandshakeResult(succeeded: [], failed: failed))
            }
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
        }
    }
}
