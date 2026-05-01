import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @State private var clients: [ClientPermissions] = []
    @State private var activityLog: [ActivityEntry] = []
    @State private var showConnectSheet = false
    @State private var clientToUnpair: ClientPermissions?
    @Environment(\.scenePhase) private var scenePhase

    private var signedTodayCount: Int {
        let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        return activityLog.filter { $0.status == "signed" && $0.timestamp >= startOfDay }.count
    }

    private var pendingCount: Int {
        appState.pendingRequests.count
    }

    private var sortedClients: [ClientPermissions] {
        clients.sorted { $0.lastSeen > $1.lastSeen }
    }

    var body: some View {
        NavigationStack {
            List {
                // Pending approvals
                if !appState.pendingRequests.isEmpty {
                    Section {
                        PendingApprovalsView()
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                // Identity
                Section {
                    identityBar
                        .padding(.bottom, 8)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                // Stats
                Section {
                    statsRow
                        .padding(.bottom, 8)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                // Connected Clients
                Section {
                    if clients.isEmpty {
                        emptyClientsView
                    } else {
                        ForEach(sortedClients) { client in
                            NavigationLink(destination: ClientDetailView(pubkey: client.pubkey)) {
                                clientRow(client)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    clientToUnpair = client
                                } label: {
                                    Label("Unpair", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("Connected Clients")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Clave")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showConnectSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .onAppear { refreshData() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshData() }
            }
            // Bug H fix: refresh clients + activity when the user switches
            // account via the identity-bar Menu. Without this, the npub label
            // (read directly from appState.currentAccount) updates correctly
            // but the @State `clients` and `activityLog` arrays were only
            // reloaded by refreshData() — which fired on appear / scenePhase
            // / signingCompleted but never on currentAccount change.
            .onChange(of: appState.currentAccount?.pubkeyHex) { _, _ in
                refreshData()
            }
            .onReceive(NotificationCenter.default.publisher(for: .signingCompleted)) { _ in
                refreshData()
            }
            .sheet(isPresented: $showConnectSheet, onDismiss: {
                refreshData()
            }) {
                ConnectSheet()
            }
            .alert("Unpair Client?", isPresented: Binding(
                get: { clientToUnpair != nil },
                set: { if !$0 { clientToUnpair = nil } }
            )) {
                Button("Unpair", role: .destructive) {
                    if let client = clientToUnpair {
                        withAnimation {
                            appState.unpairClientWithProxy(clientPubkey: client.pubkey)
                            // Task 4: scoped variant — removes only this
                            // (signer, client) pair, never another account's
                            // row for the same client. Phase 1 = single
                            // account in field, so currentAccount.pubkeyHex
                            // is unambiguous.
                            SharedStorage.removeClientPermissions(
                                signer: appState.signerPubkeyHex,
                                client: client.pubkey
                            )
                            refreshData()
                        }
                    }
                    clientToUnpair = nil
                }
                Button("Cancel", role: .cancel) {
                    clientToUnpair = nil
                }
            } message: {
                Text("This client will need a new bunker URI with a fresh secret to reconnect.")
            }
        }
    }

    // MARK: - Identity Bar

    private var identityBar: some View {
        HStack(spacing: 12) {
            // Tap-to-switch account menu. Wraps the avatar+name+npub block;
            // the copy-npub button stays separate so tapping it doesn't
            // open the menu. Stage C will replace this with a richer bottom-
            // sheet picker (see ~/.claude/plans/doesnt-each-account-have-
            // dreamy-journal.md), but a Menu is the smallest possible
            // interim affordance for testers who don't want to dig into
            // Settings → dev menu every time they switch accounts.
            Menu {
                ForEach(appState.accounts) { account in
                    Button {
                        appState.switchToAccount(pubkey: account.pubkeyHex)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        if account.pubkeyHex == appState.currentAccount?.pubkeyHex {
                            Label(accountLabel(account), systemImage: "checkmark")
                        } else {
                            Text(accountLabel(account))
                        }
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    profileAvatar
                    VStack(alignment: .leading, spacing: 4) {
                        if let name = appState.profile?.displayName, !name.isEmpty {
                            Text(name)
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                        }
                        Text(truncatedNpub)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if appState.accounts.count > 1 {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                UIPasteboard.general.string = appState.npub
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
            }

            Spacer()

            HStack(spacing: 4) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("Active")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 8)
        .onAppear { appState.fetchProfileIfNeeded() }
    }

    /// Display label for the account picker menu item. Prefers explicit
    /// petname, falls back to kind:0 displayName, then to a truncated
    /// pubkey hex.
    private func accountLabel(_ account: Account) -> String {
        if let petname = account.petname, !petname.isEmpty { return petname }
        if let display = account.profile?.displayName, !display.isEmpty { return display }
        let pk = account.pubkeyHex
        guard pk.count > 12 else { return pk }
        return String(pk.prefix(8)) + "…" + String(pk.suffix(4))
    }

    @ViewBuilder
    private var profileAvatar: some View {
        if let image = appState.profileImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(Circle())
        } else {
            AvatarView(pubkeyHex: appState.signerPubkeyHex, name: appState.profile?.displayName)
        }
    }

    private var truncatedNpub: String {
        let npub = appState.npub
        guard npub.count > 20 else { return npub }
        return String(npub.prefix(12)) + "..." + String(npub.suffix(6))
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack(spacing: 12) {
            statCard(title: "Signed Today", value: "\(signedTodayCount)", icon: "checkmark.circle.fill", color: .green)
            statCard(title: "Clients", value: "\(clients.count)", icon: "person.2.fill", color: .blue)
            statCard(title: "Pending", value: "\(pendingCount)", icon: "clock.badge.exclamationmark.fill", color: .orange)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func statCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.title2.bold())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Connected Clients

    private var emptyClientsView: some View {
        HStack {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text("No clients connected")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Connect a Nostr client like Nostur or noStrudel to start signing events remotely.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                Button {
                    showConnectSheet = true
                } label: {
                    Label("Connect a Client", systemImage: "plus.circle.fill")
                        .font(.body.bold())
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 32)
            }
            .padding(.vertical, 40)
            Spacer()
        }
    }

    private func clientRow(_ client: ClientPermissions) -> some View {
        HStack(spacing: 12) {
            // Client image or fallback avatar
            if let imageURL = client.imageURL, let url = URL(string: imageURL) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    AvatarView(pubkeyHex: client.pubkey, name: client.name, size: 32)
                }
                .frame(width: 32, height: 32)
                .clipShape(Circle())
            } else {
                AvatarView(pubkeyHex: client.pubkey, name: client.name, size: 32)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(client.name ?? truncatedPubkey(client.pubkey))
                        .font(.subheadline)
                    trustBadge(client.trustLevel)
                }
                Text("Last seen \(relativeTime(client.lastSeen))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(client.requestCount)")
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.1), in: Capsule())
        }
    }

    private func trustBadge(_ level: TrustLevel) -> some View {
        let (text, color): (String, Color) = switch level {
        case .full: ("Full", .green)
        case .medium: ("Medium", .blue)
        case .low: ("Low", .orange)
        }
        return Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: - Helpers

    private func refreshData() {
        SharedStorage.migrateIfNeeded()
        // Task 7: scope to the current account. Phase 1 single-account
        // user sees the same data as before; Phase 2 multi-account user
        // sees only the current account's activity.
        clients = SharedStorage.getClientPermissions(forSigner: appState.signerPubkeyHex)
        activityLog = SharedStorage.getActivityLog(for: appState.signerPubkeyHex)
        appState.refreshPendingRequests()
        appState.refreshBunkerSecret()
    }

    private func truncatedPubkey(_ hex: String) -> String {
        guard hex.count > 12 else { return hex }
        return String(hex.prefix(8)) + "..." + String(hex.suffix(4))
    }

    private func relativeTime(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
