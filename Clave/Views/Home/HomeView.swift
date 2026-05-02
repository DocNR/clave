import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @State private var clients: [ClientPermissions] = []
    @State private var activityLog: [ActivityEntry] = []
    @State private var showConnectSheet = false
    @State private var clientToUnpair: ClientPermissions?
    @State private var showAddAccountSheet = false
    @State private var navigationPath = NavigationPath()
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
        NavigationStack(path: $navigationPath) {
            List {
                // Pending approvals
                if !appState.pendingRequests.isEmpty {
                    Section {
                        PendingApprovalsView()
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                // Stage C: strip + slim bar replace the build-37 Menu identity bar.
                Section {
                    AccountStripView(showAddSheet: $showAddAccountSheet)
                    SlimIdentityBar()
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
                    pairNewConnectionRow

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
            .scrollContentBackground(.hidden)
            .navigationTitle("Clave")
            .onAppear {
                refreshData()
                appState.fetchProfileIfNeeded()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshData() }
            }
            // Bug H fix: refresh clients + activity when the user switches
            // account via the strip pills. Without this, the npub label
            // (read directly from appState.currentAccount) updates correctly
            // but the @State `clients` and `activityLog` arrays were only
            // reloaded by refreshData() — which fired on appear / scenePhase
            // / signingCompleted but never on currentAccount change.
            .onChange(of: appState.currentAccount?.pubkeyHex) { _, _ in
                refreshData()
            }
            .onChange(of: appState.pendingDetailPubkey) { _, newValue in
                if let pubkey = newValue {
                    navigationPath.append(AccountNavTarget.detail(pubkey: pubkey))
                    appState.pendingDetailPubkey = nil
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .signingCompleted)) { _ in
                refreshData()
            }
            .navigationDestination(for: AccountNavTarget.self) { target in
                switch target {
                case .detail(let pubkey):
                    AccountDetailView(pubkeyHex: pubkey)
                }
            }
            .sheet(isPresented: $showConnectSheet, onDismiss: {
                refreshData()
            }) {
                ConnectSheet()
            }
            .sheet(isPresented: $showAddAccountSheet) {
                AddAccountSheet()
            }
            .alert(swipeUnpairAlertTitle, isPresented: Binding(
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
                Text("This connection will no longer be able to sign for this account.")
            }
        }
        .background(homeBackgroundGradient.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.3), value: appState.currentAccount?.pubkeyHex)
    }

    // MARK: - Unpair alert helpers

    private var homeCurrentAccountDisplayName: String {
        guard let account = appState.currentAccount else {
            return String(appState.signerPubkeyHex.prefix(8))
        }
        if let p = account.petname, !p.isEmpty { return p }
        if let d = account.profile?.displayName, !d.isEmpty { return d }
        return String(account.pubkeyHex.prefix(8))
    }

    private var swipeUnpairAlertTitle: String {
        let clientName = clientToUnpair?.name ?? "this connection"
        return "Unpair \(clientName) from @\(homeCurrentAccountDisplayName)?"
    }

    // MARK: - Background gradient

    private var homeBackgroundGradient: some View {
        let theme: AccountTheme
        if let current = appState.currentAccount {
            theme = AccountTheme.forAccount(pubkeyHex: current.pubkeyHex)
        } else {
            theme = AccountTheme.palette[0]
        }
        return LinearGradient(
            stops: [
                .init(color: theme.start.opacity(0.35), location: 0.0),
                .init(color: theme.end.opacity(0.22), location: 0.35),
                .init(color: theme.end.opacity(0.14), location: 0.70),
                .init(color: theme.start.opacity(0.10), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
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

    private var pairNewConnectionRow: some View {
        Button {
            showConnectSheet = true
        } label: {
            HStack(spacing: 12) {
                pairNewConnectionIcon
                pairNewConnectionLabel
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private var pairNewConnectionIcon: some View {
        Image(systemName: "link.badge.plus")
            .font(.title3)
            .foregroundStyle(Color.accentColor)
            .frame(width: 32, height: 32)
    }

    private var pairNewConnectionLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Pair New Connection")
                .font(.subheadline.bold())
                .foregroundStyle(.primary)
            Text("Add a NIP-46 client to sign with this account")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

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
