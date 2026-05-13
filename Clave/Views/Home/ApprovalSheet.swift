import SwiftUI

struct ApprovalSheet: View {
    let parsedURI: NostrConnectParser.ParsedURI
    /// Account(s) the user picked in ConnectAccountPicker. Phase 2 multi-account:
    /// may contain 2+ pubkeys when the client requested `accounts=multi` and the
    /// user selected multiple. Single-mode (count == 1) preserves Phase 1 UX.
    /// May be empty in degenerate paths; downstream guards treat empty as no-op.
    let boundAccountPubkeys: [String]
    let onApprove: (ClientPermissions) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var selectedTrust: TrustLevel
    @State private var kindOverrides: [Int: Bool] = [:]
    @State private var showPermissions = false
    @State private var showConnectionCapAlert = false

    private let protectedKinds: Set<Int> = SharedStorage.getProtectedKinds()

    init(parsedURI: NostrConnectParser.ParsedURI,
         boundAccountPubkeys: [String] = [],
         onApprove: @escaping (ClientPermissions) -> Void) {
        self.parsedURI = parsedURI
        self.boundAccountPubkeys = boundAccountPubkeys
        self.onApprove = onApprove
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
                    trustLevelCards
                    permissionsSection
                    actionButtons
                }
                .padding()
            }
            .navigationTitle("Approve Connection")
            .navigationBarTitleDisplayMode(.inline)
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
        onApprove(permissions)
        // Don't call dismiss() here — ConnectSheet handles dismissal
        // by setting parsedURI = nil on the .sheet(item:) binding.
    }
}
