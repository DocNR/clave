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
    /// Authoritative per-row outcome captured at end of `runHandshake`.
    /// Drives the partial-failure result view (Task 11): per-row error
    /// messages + per-row Retry buttons. Mutated in place during retry
    /// to move entries between `failed` and `succeeded`.
    @State private var handshakeResult: HandshakeResult? = nil
    /// In-flight retry tracking — disables the Retry button while the
    /// per-signer handshake re-runs. Prevents double-tap from launching
    /// two simultaneous handshakes for the same signer.
    @State private var retryingSigners: Set<String> = []

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
                        // and the per-row result view renders (Task 11).
                        resultView
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
            // Block swipe-dismiss during the handshake loop AND during the
            // partial-failure result view — otherwise the user can swipe
            // away unretried failures with no second chance. Done is the
            // only exit from the partial state. All-success and all-failure
            // dismissals are driven by the parent's onCompletion, so this
            // guard never blocks them.
            .interactiveDismissDisabled(
                isConnecting
                    || (handshakeCompleted
                        && (handshakeResult?.isPartialFailure ?? false))
            )
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
            CachedAccountAvatarView(pubkeyHex: pubkey,
                                    displayLabel: account?.displayLabel,
                                    size: 28)
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

    // MARK: - Result View (Task 11)

    /// Rendered after the handshake loop completes (handshakeCompleted=true).
    /// Three variants:
    ///   - all-success: brief checkmark + names. Parent dismisses immediately
    ///     on isAllSuccess (Option B per Task 11 design notes — the spec's
    ///     1.5s flash is skipped in favor of an immediate dismiss; this view
    ///     is visible for at most one frame). The success view is implemented
    ///     defensively so a future Option A switch (parent waits for sheet
    ///     self-dismiss) only requires re-wiring the parent.
    ///   - partial-failure: header "M of N paired" + per-row error + Retry,
    ///     plus a Done button. Sheet stays open until user taps Done. swipe-
    ///     dismiss is blocked via interactiveDismissDisabled.
    ///   - all-failure: parent dismisses + alerts; nothing rendered here.
    @ViewBuilder
    private var resultView: some View {
        if let result = handshakeResult {
            if result.isAllSuccess {
                successResultView(result)
            } else if result.isPartialFailure {
                partialFailureResultView(result)
            }
            // all-failure: parent dismisses immediately → nothing to render.
        } else {
            // Race window: handshakeCompleted latched but result not yet
            // assigned (single frame). Keep the user looking at something
            // sensible rather than empty space.
            ProgressView()
                .controlSize(.small)
                .padding(.vertical, 24)
        }
    }

    /// Success-only post-loop view. Rendered for one-frame in Option B
    /// (parent dismisses immediately) — visible if a future Option A
    /// switches the parent to wait for the sheet's self-dismiss signal.
    private func successResultView(_ result: HandshakeResult) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text(successMessage(for: result))
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private func successMessage(for result: HandshakeResult) -> String {
        let names = result.succeeded.map { pubkey in
            appState.accounts.first(where: { $0.pubkeyHex == pubkey })?.displayLabel
                ?? String(pubkey.prefix(8))
        }.joined(separator: ", ")
        return "\(clientDisplayName) is now signed in for \(names)"
    }

    /// Partial-failure result view — the user sees which signers succeeded
    /// and which failed, with a per-row Retry button. Done dismisses;
    /// swipe-dismiss is blocked via interactiveDismissDisabled to prevent
    /// orphaning unretried failures.
    private func partialFailureResultView(_ result: HandshakeResult) -> some View {
        let total = result.succeeded.count + result.failed.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("\(result.succeeded.count) of \(total) paired successfully")
                    .font(.headline)
            }
            ForEach(result.succeeded, id: \.self) { pubkey in
                succeededRow(pubkey: pubkey)
            }
            ForEach(result.failed, id: \.signerPubkey) { failed in
                failedRow(failed)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
        }
        .padding(.vertical, 12)
    }

    private func succeededRow(pubkey: String) -> some View {
        let account = appState.accounts.first(where: { $0.pubkeyHex == pubkey })
        let label = account?.displayLabel ?? String(pubkey.prefix(8))
        return HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
                .frame(width: 24, height: 24)
            CachedAccountAvatarView(pubkeyHex: pubkey,
                                    displayLabel: account?.displayLabel,
                                    size: 28)
            Text(label)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private func failedRow(_ failed: HandshakeResult.FailedSigner) -> some View {
        let account = appState.accounts.first(where: { $0.pubkeyHex == failed.signerPubkey })
        let label = account?.displayLabel ?? String(failed.signerPubkey.prefix(8))
        return HStack(spacing: 10) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.title3)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(failed.errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button("Retry") {
                retryFailed(signer: failed.signerPubkey)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(retryingSigners.contains(failed.signerPubkey))
        }
        .padding(8)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    /// Re-runs the handshake for a single failed signer. Mutates
    /// `handshakeResult` in place: success moves the entry from `failed`
    /// to `succeeded`; failure updates the error message inline. If retry
    /// drains `failed` to empty, signals the parent via `onCompletion` so
    /// the parent's all-success branch fires and the sheet dismisses.
    ///
    /// Retry uses a fresh ClientPermissions template rebuilt from the
    /// current trust/override state (same as buildAndApprove). The
    /// AppState+NostrConnect layer's per-signer rewrite (see
    /// runSingleConnect) ensures the row gets keyed to *this* signer
    /// before save.
    private func retryFailed(signer: String) {
        // Guard against double-tap mid-retry.
        guard !retryingSigners.contains(signer) else { return }
        retryingSigners.insert(signer)
        let perms = ClientPermissions(
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
            signerPubkeyHex: signer
        )
        Task { @MainActor in
            do {
                let retryResult = try await appState.handleNostrConnect(
                    parsedURI: parsedURI,
                    signerPubkeys: [signer],
                    permissions: perms
                )
                retryingSigners.remove(signer)
                guard let current = handshakeResult else { return }
                if retryResult.isAllSuccess {
                    let updated = HandshakeResult(
                        succeeded: current.succeeded + [signer],
                        failed: current.failed.filter { $0.signerPubkey != signer }
                    )
                    handshakeResult = updated
                    succeededSoFar.insert(signer)
                    // If all rows are now succeeded, signal the parent so
                    // it dismisses + clears its staged state. Without this
                    // the sheet would sit at "M of M paired successfully"
                    // with no failures, which is a dead-end UX (Done
                    // works, but the all-success path should match the
                    // initial-loop all-success path).
                    if updated.isAllSuccess {
                        onCompletion(updated)
                    }
                } else {
                    // handleNostrConnect returned a non-success result for
                    // this single-signer retry (it caught the throw
                    // internally and packaged it as a FailedSigner).
                    let newError = retryResult.failed.first?.errorMessage
                        ?? "Retry failed"
                    let updatedFailed = current.failed.map { f -> HandshakeResult.FailedSigner in
                        if f.signerPubkey == signer {
                            return HandshakeResult.FailedSigner(
                                signerPubkey: signer,
                                errorMessage: newError
                            )
                        }
                        return f
                    }
                    handshakeResult = HandshakeResult(
                        succeeded: current.succeeded,
                        failed: updatedFailed
                    )
                }
            } catch {
                // Boundary throw (e.g., empty signers — shouldn't happen
                // since we pass [signer]). Update the row's error message
                // in place; row stays for further retries.
                retryingSigners.remove(signer)
                guard let current = handshakeResult else { return }
                let updatedFailed = current.failed.map { f -> HandshakeResult.FailedSigner in
                    if f.signerPubkey == signer {
                        return HandshakeResult.FailedSigner(
                            signerPubkey: signer,
                            errorMessage: error.localizedDescription
                        )
                    }
                    return f
                }
                handshakeResult = HandshakeResult(
                    succeeded: current.succeeded,
                    failed: updatedFailed
                )
            }
        }
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
            CachedAccountAvatarView(pubkeyHex: pubkey,
                                    displayLabel: account?.displayLabel,
                                    size: 28)
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
                handshakeResult = result
                onCompletion(result)
            } catch {
                // Boundary error (e.g., empty signers) — synthesize an
                // all-failure result so the parent treats it uniformly.
                isConnecting = false
                handshakeCompleted = true
                // Empty-signers edge case: signers.map yields []; that produces
                // HandshakeResult(succeeded: [], failed: []) where all three
                // boolean flags are false → parent doesn't dismiss → sheet
                // stuck-open with no recourse. Synthesize one entry so
                // isAllFailure is true and the parent dismisses + alerts.
                let failed: [HandshakeResult.FailedSigner] = signers.isEmpty
                    ? [HandshakeResult.FailedSigner(
                        signerPubkey: "",
                        errorMessage: error.localizedDescription
                      )]
                    : signers.map {
                        HandshakeResult.FailedSigner(
                            signerPubkey: $0,
                            errorMessage: error.localizedDescription
                        )
                    }
                let synthesized = HandshakeResult(succeeded: [], failed: failed)
                handshakeResult = synthesized
                onCompletion(synthesized)
            }
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
        }
    }
}
