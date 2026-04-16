import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @State private var clients: [ConnectedClient] = []
    @State private var activityLog: [ActivityEntry] = []
    @State private var showQR = false
    @State private var copiedBunker = false
    @State private var clientToUnpair: ConnectedClient?
    @State private var clientToRename: ConnectedClient?
    @State private var renameText = ""
    @Environment(\.scenePhase) private var scenePhase

    private var signedTodayCount: Int {
        let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        return activityLog.filter { $0.status == "signed" && $0.timestamp >= startOfDay }.count
    }

    private var pendingCount: Int {
        appState.pendingRequests.count
    }

    private var sortedClients: [ConnectedClient] {
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

                // Bunker URI
                Section {
                    bunkerCard
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
                            clientRow(client)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    renameText = client.name ?? ""
                                    clientToRename = client
                                }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                let client = sortedClients[index]
                                if SharedStorage.isClientPaired(client.pubkey) {
                                    clientToUnpair = client
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
            .onAppear { refreshData() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshData() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .signingCompleted)) { _ in
                refreshData()
            }
            .sheet(isPresented: $showQR) {
                QRCodeView(content: appState.bunkerURI)
            }
            .alert("Unpair Client?", isPresented: Binding(
                get: { clientToUnpair != nil },
                set: { if !$0 { clientToUnpair = nil } }
            )) {
                Button("Unpair", role: .destructive) {
                    if let client = clientToUnpair {
                        withAnimation {
                            SharedStorage.removeClientPermissions(for: client.pubkey)
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
            .alert("Rename Client", isPresented: Binding(
                get: { clientToRename != nil },
                set: { if !$0 { clientToRename = nil } }
            )) {
                TextField("Client name", text: $renameText)
                Button("Save") {
                    if let client = clientToRename {
                        SharedStorage.renameClient(pubkey: client.pubkey, name: renameText.isEmpty ? nil : renameText)
                        refreshData()
                    }
                    clientToRename = nil
                }
                Button("Cancel", role: .cancel) {
                    clientToRename = nil
                }
            } message: {
                Text("Give this client a name so you can identify it.")
            }
        }
    }

    // MARK: - Identity Bar

    private var identityBar: some View {
        HStack(spacing: 12) {
            profileAvatar

            VStack(alignment: .leading, spacing: 4) {
                if let name = appState.profile?.displayName, !name.isEmpty {
                    Text(name)
                        .font(.subheadline.bold())
                }

                HStack(spacing: 6) {
                    Text(truncatedNpub)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Button {
                        UIPasteboard.general.string = appState.npub
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                    }
                }
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

    @ViewBuilder
    private var profileAvatar: some View {
        if let image = appState.profileImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(Circle())
        } else {
            AvatarView(pubkeyHex: appState.signerPubkeyHex)
        }
    }

    private var truncatedNpub: String {
        let npub = appState.npub
        guard npub.count > 20 else { return npub }
        return String(npub.prefix(12)) + "..." + String(npub.suffix(6))
    }

    // MARK: - Bunker URI Card

    private var bunkerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Bunker Address")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    appState.rotateBunkerSecret()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } label: {
                    Label("New Secret", systemImage: "arrow.clockwise")
                        .font(.caption2)
                }
            }

            Text(appState.bunkerURI)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(3)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray6).opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = appState.bunkerURI
                    copiedBunker = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedBunker = false }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: copiedBunker ? "checkmark" : "doc.on.doc")
                        Text(copiedBunker ? "Copied" : "Copy")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(copiedBunker ? .green : .accentColor)

                Button {
                    showQR = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "qrcode")
                        Text("QR Code")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Text("Each secret is single-use. Tap New Secret to generate a fresh pairing link.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemGray6))
        }
        .padding(.horizontal)
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
            VStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.title)
                    .foregroundStyle(.tertiary)
                Text("No clients connected yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 24)
            Spacer()
        }
    }

    private func clientRow(_ client: ConnectedClient) -> some View {
        let isPaired = SharedStorage.isClientPaired(client.pubkey)
        return HStack(spacing: 12) {
            AvatarView(pubkeyHex: client.pubkey, size: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(client.name ?? truncatedPubkey(client.pubkey))
                        .font(.subheadline)
                    if isPaired {
                        Text("Paired")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                    }
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

    // MARK: - Helpers

    private func refreshData() {
        clients = SharedStorage.getConnectedClients()
        activityLog = SharedStorage.getActivityLog()
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
