import SwiftUI

struct ApprovalSheet: View {
    let parsedURI: NostrConnectParser.ParsedURI
    let onApprove: (ClientPermissions) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var selectedTrust: TrustLevel
    @State private var kindOverrides: [Int: Bool] = [:]
    @State private var showPermissions = false
    @State private var capExceeded = false

    private let protectedKinds: Set<Int> = SharedStorage.getProtectedKinds()

    init(parsedURI: NostrConnectParser.ParsedURI, onApprove: @escaping (ClientPermissions) -> Void) {
        self.parsedURI = parsedURI
        self.onApprove = onApprove
        _selectedTrust = State(initialValue: parsedURI.suggestedTrustLevel)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    SigningAsHeader(signerPubkeyHex: appState.signerPubkeyHex)
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
            .alert("Free tier limit reached", isPresented: $capExceeded) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("You've paired the maximum 5 clients. Unpair one from Settings → Clients to continue.")
            }
        }
        .snapshotProtected()
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

            Button("Connect as @\(signingAsDisplayLabel)") {
                buildAndApprove()
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
    }

    // MARK: - Helpers

    private var signingAsDisplayLabel: String {
        let pk = appState.signerPubkeyHex
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
        let currentSigner = SharedConstants.sharedDefaults.string(
            forKey: SharedConstants.currentSignerPubkeyHexKey
        ) ?? ""
        let connected = SharedStorage.getConnectedClients(for: currentSigner)
        let alreadyPaired = connected.contains { $0.pubkey == parsedURI.clientPubkey }
        if !alreadyPaired && connected.count >= 5 {
            capExceeded = true
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
            signerPubkeyHex: currentSigner
        )
        onApprove(permissions)
        // Don't call dismiss() here — ConnectSheet handles dismissal
        // by setting parsedURI = nil on the .sheet(item:) binding.
    }
}
