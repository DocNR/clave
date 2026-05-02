import SwiftUI

struct ClientDetailView: View {
    let pubkey: String

    @Environment(AppState.self) private var appState
    @State private var permissions: ClientPermissions?
    @State private var selectedTrust: TrustLevel = .medium
    @State private var kindOverrides: [Int: Bool] = [:]
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showUnpairConfirm = false
    @State private var showOverrideAlert = false
    @State private var pendingTrustLevel: TrustLevel?
    @State private var showPermissions = false
    @State private var showConnectionInfo = false
    @Environment(\.dismiss) private var dismiss

    private let protectedKinds: Set<Int> = SharedStorage.getProtectedKinds()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let perms = permissions {
                    clientHeader(perms)
                    trustLevelSection
                    permissionsSection
                    recentActivitySection
                } else {
                    ContentUnavailableView(
                        "Client Not Found",
                        systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("No permissions found for this client.")
                    )
                }
            }
            .padding()
        }
        .navigationTitle(permissions?.name ?? "Client")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if permissions != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showConnectionInfo = true
                        } label: {
                            Label("Connection Info", systemImage: "info.circle")
                        }
                        Button {
                            renameText = permissions?.name ?? ""
                            showRename = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Divider()
                        Button(role: .destructive) {
                            showUnpairConfirm = true
                        } label: {
                            Label("Unpair Client", systemImage: "link.badge.plus")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .onAppear(perform: loadPermissions)
        .sheet(isPresented: $showConnectionInfo) {
            if let perms = permissions {
                ConnectionInfoSheet(perms: perms)
            }
        }
        .alert("Rename Client", isPresented: $showRename) {
            TextField("Client name", text: $renameText)
            Button("Save") { performRename() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter a new name for this client.")
        }
        .alert(unpairAlertTitle, isPresented: $showUnpairConfirm) {
            Button("Unpair", role: .destructive) { performUnpair() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(unpairAlertMessage)
        }
        .alert("Clear Overrides?", isPresented: $showOverrideAlert) {
            Button("Change & Clear") {
                if let level = pendingTrustLevel {
                    kindOverrides = [:]
                    selectedTrust = level
                    saveChanges()
                }
                pendingTrustLevel = nil
            }
            Button("Cancel", role: .cancel) {
                pendingTrustLevel = nil
            }
        } message: {
            Text("Changing the trust level will clear your per-kind permission overrides.")
        }
    }

    // MARK: - Load

    private func loadPermissions() {
        // Task 7: scope to (current account, this client). Phase-2
        // multi-account: same client paired with multiple accounts
        // produces distinct rows; this loads the current account's row.
        if let perms = SharedStorage.getClientPermissions(signer: appState.signerPubkeyHex, client: pubkey) {
            permissions = perms
            selectedTrust = perms.trustLevel
            kindOverrides = perms.kindOverrides
        }
    }

    // MARK: - Client Header

    private func clientHeader(_ perms: ClientPermissions) -> some View {
        VStack(spacing: 12) {
            if let imageURLString = perms.imageURL,
               let url = URL(string: imageURLString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: 72, height: 72)
                            .clipShape(Circle())
                    default:
                        AvatarView(pubkeyHex: pubkey, name: perms.name, size: 72)
                    }
                }
            } else {
                AvatarView(pubkeyHex: pubkey, name: perms.name, size: 72)
            }

            Button {
                renameText = perms.name ?? ""
                showRename = true
            } label: {
                HStack(spacing: 6) {
                    Text(perms.name ?? truncatedPubkey)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Tap to rename")

            if let url = perms.url {
                Text(url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Connected \(relativeTime(perms.connectedAt))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: - Trust Level

    private var trustLevelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trust Level")
                .font(.headline)
                .padding(.leading, 4)

            trustCard(level: .full, title: "Full Trust", subtitle: "Auto-sign all requests", color: .green)
            trustCard(level: .medium, title: "Medium Trust", subtitle: "Ask for sensitive operations", color: .blue)
            trustCard(level: .low, title: "Low Trust", subtitle: "Ask for every request", color: .orange)
        }
    }

    private func trustCard(level: TrustLevel, title: String, subtitle: String, color: Color) -> some View {
        let isSelected = selectedTrust == level
        return Button {
            changeTrustLevel(to: level)
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

    private func changeTrustLevel(to level: TrustLevel) {
        guard level != selectedTrust else { return }
        if !kindOverrides.isEmpty {
            pendingTrustLevel = level
            showOverrideAlert = true
        } else {
            selectedTrust = level
            saveChanges()
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        DisclosureGroup("Permissions", isExpanded: $showPermissions) {
            VStack(alignment: .leading, spacing: 16) {
                signingSubsection
                encryptionSubsection
            }
            .padding(.top, 8)
        }
    }

    private var signingSubsection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Signing")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(allKindsSorted, id: \.self) { kind in
                kindPermissionRow(for: kind)
                if kind != allKindsSorted.last {
                    Divider()
                }
            }
        }
    }

    private func kindPermissionRow(for kind: Int) -> some View {
        let defaultValue = defaultForTrustLevel(kind)
        let binding = Binding<Bool>(
            get: { kindOverrides[kind] ?? defaultValue },
            set: { newValue in
                if newValue == defaultForTrustLevel(kind) {
                    kindOverrides.removeValue(forKey: kind)
                } else {
                    kindOverrides[kind] = newValue
                }
                saveChanges()
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

    private var encryptionSubsection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Encryption")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(encryptionMethods, id: \.self) { method in
                methodPermissionRow(for: method)
                if method != encryptionMethods.last {
                    Divider()
                }
            }
        }
    }

    private let encryptionMethods = [
        "nip04_encrypt", "nip04_decrypt",
        "nip44_encrypt", "nip44_decrypt"
    ]

    private func methodPermissionRow(for method: String) -> some View {
        let binding = Binding<Bool>(
            get: { permissions?.methodPermissions.contains(method) ?? false },
            set: { newValue in
                if newValue {
                    permissions?.methodPermissions.insert(method)
                } else {
                    permissions?.methodPermissions.remove(method)
                }
                saveChanges()
            }
        )

        return Toggle(isOn: binding) {
            Text(methodLabel(method))
                .font(.subheadline)
        }
        .padding(.vertical, 4)
        .padding(.trailing, 4)
    }

    private func methodLabel(_ method: String) -> String {
        switch method {
        case "nip04_encrypt": return "NIP-04 Encrypt"
        case "nip04_decrypt": return "NIP-04 Decrypt"
        case "nip44_encrypt": return "NIP-44 Encrypt"
        case "nip44_decrypt": return "NIP-44 Decrypt"
        default: return method
        }
    }

    // MARK: - Recent Activity

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Activity")
                .font(.headline)
                .padding(.leading, 4)

            let entries = clientActivityEntries
            if entries.isEmpty {
                Text("No activity yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        NavigationLink {
                            ActivityDetailView(entry: entry)
                        } label: {
                            HStack {
                                ActivityRowView(entry: entry, showsClientName: false)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())

                        if entry.id != entries.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var clientActivityEntries: [ActivityEntry] {
        // Task 7: scope to current account's activity. The client we're
        // viewing may also be paired with another account, but this
        // detail view is scoped to (current signer, this client) — only
        // show activity that THIS account had with this client.
        Array(
            SharedStorage.getActivityLog(for: appState.signerPubkeyHex)
                .filter { $0.clientPubkey == pubkey }
                .sorted { $0.timestamp > $1.timestamp }
                .prefix(20)
        )
    }

    // MARK: - Persistence

    private func saveChanges() {
        guard var perms = permissions else { return }
        perms.trustLevel = selectedTrust
        perms.kindOverrides = kindOverrides
        SharedStorage.saveClientPermissions(perms)
        permissions = perms
    }

    private func performRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var perms = permissions else { return }
        perms.name = trimmed
        SharedStorage.saveClientPermissions(perms)
        permissions = perms
    }

    private func performUnpair() {
        appState.unpairClientWithProxy(clientPubkey: pubkey)
        // Task 4: scoped variant. See HomeView for rationale.
        SharedStorage.removeClientPermissions(
            signer: appState.signerPubkeyHex,
            client: pubkey
        )
        dismiss()
    }

    // MARK: - Helpers

    private var unpairAlertTitle: String {
        let clientName = permissions?.name ?? "this connection"
        let accountLabel = currentAccountDisplayName
        return "Unpair \(clientName) from @\(accountLabel)?"
    }

    private var unpairAlertMessage: String {
        "This connection will no longer be able to sign for this account."
    }

    private var currentAccountDisplayName: String {
        guard let account = appState.currentAccount else {
            return String(appState.signerPubkeyHex.prefix(8))
        }
        if let p = account.petname, !p.isEmpty { return p }
        if let d = account.profile?.displayName, !d.isEmpty { return d }
        return String(account.pubkeyHex.prefix(8))
    }

    private var truncatedPubkey: String {
        if pubkey.count > 12 {
            return String(pubkey.prefix(8)) + "..." + String(pubkey.suffix(4))
        }
        return pubkey
    }

    private var allKindsSorted: [Int] {
        var kinds = Set<Int>()

        // Task 7: scope to current account's history with this client.
        let clientKinds = SharedStorage.getActivityLog(for: appState.signerPubkeyHex)
            .filter { $0.clientPubkey == pubkey }
            .compactMap { $0.eventKind }
        kinds.formUnion(clientKinds)

        // All protected kinds
        kinds.formUnion(protectedKinds)

        // Common kinds: notes, reposts, reactions
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

    private func relativeTime(_ timestamp: Double) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(
            for: Date(timeIntervalSince1970: timestamp),
            relativeTo: Date()
        )
    }
}
