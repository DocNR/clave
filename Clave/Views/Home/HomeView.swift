import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @State private var clients: [ClientPermissions] = []
    @State private var activityLog: [ActivityEntry] = []
    @State private var showConnectSheet = false
    @State private var clientToUnpair: ClientPermissions?
    @State private var showAddAccountSheet = false
    @State private var showAccountCapAlert = false
    @State private var showConnectionCapAlert = false
    @State private var showInboxSheet = false
    @State private var navigationPath = NavigationPath()
    @State private var deeplinkApprovalURI: NostrConnectParser.ParsedURI?
    @State private var deeplinkAccountChoiceURI: NostrConnectParser.ParsedURI?
    @State private var deeplinkError: String?
    @Environment(\.scenePhase) private var scenePhase

    private var signedTodayCount: Int {
        let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        return activityLog.filter { $0.status == "signed" && $0.timestamp >= startOfDay }.count
    }

    /// Drives the "Pending" stat card and the bell badge. Reads the
    /// freshness-filtered count from AppState so stale (>5 min) requests
    /// don't inflate the surface.
    private var pendingCount: Int {
        appState.pendingApprovalQueueDepth
    }

    private var sortedClients: [ClientPermissions] {
        clients.sorted { $0.lastSeen > $1.lastSeen }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                // Pending approvals moved out of the home list. The root
                // alert in MainTabView surfaces the active request from
                // any tab; the bell ToolbarItem opens InboxView for queue
                // triage. The orange card is deliberately gone.

                // Stage C: strip + slim bar replace the build-37 Menu identity bar.
                // SlimIdentityBar manages its own outer padding (12pt bottom);
                // no additional spacing added here.
                Section {
                    AccountStripView(onAddTapped: handleAddAccountTap)
                    SlimIdentityBar()
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                // Primary CTA — always visible. Replaces the previous
                // in-list pairNewConnectionRow + empty-state big button.
                Section {
                    connectClientButton
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                // Stats
                Section {
                    statsRow
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                // Connected Clients
                Section {
                    if clients.isEmpty {
                        emptyClientsHint
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
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .listSectionSpacing(0)
            .scrollContentBackground(.hidden)
            .background(homeBackgroundGradient.ignoresSafeArea())
            .navigationTitle("Clave")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showInboxSheet = true
                    } label: {
                        Image(systemName: pendingCount > 0 ? "bell.badge.fill" : "bell")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .accessibilityLabel(
                        pendingCount > 0
                        ? "Pending requests: \(pendingCount)"
                        : "Pending requests"
                    )
                }
            }
            .refreshable {
                refreshData()
                await appState.refreshAllProfiles()
            }
            .onAppear {
                refreshData()
                appState.fetchProfilesForAllAccountsIfNeeded()
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
            .onChange(of: appState.pendingNostrconnectURI?.id) { _, _ in
                if let uri = appState.pendingNostrconnectURI {
                    deeplinkApprovalURI = uri
                    appState.pendingNostrconnectURI = nil
                }
            }
            .onChange(of: appState.pendingDeeplinkAccountChoice?.id) { _, _ in
                if let uri = appState.pendingDeeplinkAccountChoice {
                    deeplinkAccountChoiceURI = uri
                    appState.pendingDeeplinkAccountChoice = nil
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
            .sheet(isPresented: $showInboxSheet) {
                InboxView()
            }
            .sheet(item: $deeplinkAccountChoiceURI) { uri in
                DeeplinkAccountPicker(parsedURI: uri) { pickedPubkey in
                    appState.deeplinkBoundAccount = pickedPubkey
                    let captured = uri
                    deeplinkAccountChoiceURI = nil  // dismiss picker first
                    DispatchQueue.main.async {
                        // Defer approval sheet present to the next run loop so the
                        // picker dismiss animation completes before the new sheet
                        // tries to present (SwiftUI sheet-chain race fix).
                        deeplinkApprovalURI = captured
                    }
                }
            }
            .sheet(item: $deeplinkApprovalURI) { uri in
                ApprovalSheet(
                    parsedURI: uri,
                    boundAccountPubkey: appState.deeplinkBoundAccount
                ) { permissions in
                    let captured = uri
                    let bound = appState.deeplinkBoundAccount
                    deeplinkApprovalURI = nil
                    appState.deeplinkBoundAccount = nil
                    Task {
                        do {
                            try await appState.handleNostrConnect(
                                parsedURI: captured,
                                permissions: permissions,
                                boundAccountPubkey: bound
                            )
                        } catch {
                            await MainActor.run {
                                deeplinkError = error.localizedDescription
                            }
                        }
                    }
                }
            }
            .alert("Connection Failed", isPresented: .init(
                get: { deeplinkError != nil },
                set: { if !$0 { deeplinkError = nil } }
            )) {
                Button("OK") { deeplinkError = nil }
            } message: {
                Text(deeplinkError ?? "Unknown error")
            }
            .alert("Account limit reached", isPresented: $showAccountCapAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(AccountError.accountCapReached.errorDescription ?? "")
            }
            .alert("Connection limit reached", isPresented: $showConnectionCapAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(AccountError.connectionCapReached.errorDescription ?? "")
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
        .animation(.easeInOut(duration: 0.3), value: appState.currentAccount?.pubkeyHex)
    }

    // MARK: - Add-account routing

    private func handleAddAccountTap() {
        if appState.accounts.count >= Account.maxAccountsPerDevice {
            showAccountCapAlert = true
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        } else {
            showAddAccountSheet = true
        }
    }

    /// Pre-check connection cap before opening ConnectSheet so the user
    /// hits the alert at the entry point, not after a NIP-46 connect
    /// request lands in ApprovalSheet (where ApprovalSheet's own check
    /// stays as defense-in-depth for cross-device pair attempts).
    private func handlePairNewConnectionTap() {
        if clients.count >= Account.maxClientsPerAccount {
            showConnectionCapAlert = true
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        } else {
            showConnectSheet = true
        }
    }

    // MARK: - Unpair alert helpers

    private var swipeUnpairAlertTitle: String {
        let clientName = clientToUnpair?.name ?? "this connection"
        let label = appState.currentAccount?.displayLabel
            ?? String(appState.signerPubkeyHex.prefix(8))
        return "Unpair \(clientName) from @\(label)?"
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
                .init(color: theme.start.opacity(0.42), location: 0.0),
                .init(color: theme.end.opacity(0.22), location: 0.35),
                .init(color: theme.end.opacity(0.10), location: 0.70),
                .init(color: theme.start.opacity(0.04), location: 1.0),
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
            // Pending tile routes to the same InboxView the bell opens —
            // a second affordance for the user to manage pending requests
            // without hunting for the bell. Wrapped in a Button so the
            // tile gets the standard tap-highlight; the visual treatment
            // stays identical to the non-tappable tiles. (Signed Today /
            // Clients aren't tappable here — Bug 6 in BACKLOG covers
            // routing those to filtered Activity, separate sprint.)
            Button {
                showInboxSheet = true
            } label: {
                statCard(title: "Pending", value: "\(pendingCount)", icon: "clock.badge.exclamationmark.fill", color: .orange)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the pending requests inbox")
        }
        .padding(.horizontal)
    }

    private func statCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(.primary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Primary CTA

    /// Always-visible primary CTA for the "connect a Nostr client" flow.
    /// Sits above stats / below the mini bar. Replaces the previous
    /// in-list `pairNewConnectionRow` (small themed row inside the Connected
    /// Clients section) and the in-list empty-state large button — there is
    /// now ONE surface for this action regardless of whether clients exist.
    /// Uses theme.accent so the tint matches the active account's gradient
    /// identity (consistent with the account strip, ConnectBunkerTabView's
    /// Copy URI button, and other per-account chrome).
    private var connectClientButton: some View {
        let theme = AccountTheme.forAccount(pubkeyHex: appState.currentAccount?.pubkeyHex ?? "")
        return Button {
            handlePairNewConnectionTap()
        } label: {
            // Use simple `plus` glyph (not `plus.circle.fill`) — the filled
            // variant has a negative-space plus that renders invisibly
            // against the borderedProminent fill. See Task 7 commit for
            // backstory.
            Label("Connect a Client", systemImage: "plus")
                .font(.body.bold())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(theme.accent)
        .padding(.horizontal, 16)
    }

    // MARK: - Connected Clients

    /// Small in-list hint shown when no clients are paired. The primary CTA
    /// lives above stats now (`connectClientButton`), so this surface stays
    /// minimal — just enough text to confirm "yes, you're looking at an
    /// empty list" without duplicating the action button.
    private var emptyClientsHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No clients connected yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Tap **Connect a Client** above to get started.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowBackground(Color.clear)
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
