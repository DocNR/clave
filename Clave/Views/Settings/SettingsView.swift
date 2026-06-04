import SwiftUI
import LocalAuthentication
import NostrSDK

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showAddSheet = false
    @State private var showCapAlert = false
    @State private var accountToDelete: Account?
    @State private var proxyURL = ""
    @State private var registrationStatus = ""
    @State private var devSettings = DeveloperSettings.shared
    @State private var versionTapTimes: [Date] = []
    @State private var showCopyLogsConfirmation = false
    @State private var showClearAllConnectionsAlert = false
    @State private var showReshowExplainerConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                accountsSection
                connectionsSection
                permissionsSection
                pushProxySection
                relaySection
                aboutSection
                if devSettings.developerMenuUnlocked {
                    developerSection
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                loadSettings()
            }
            // Stage C: route AccountNavTarget.detail to AccountDetailView.
            // Per Apple's NavigationStack docs, .navigationDestination must be
            // placed on a view inside the NavigationStack but OUTSIDE any
            // container view (Form/List/Section). When placed on a Section
            // (as in earlier Task 6 wiring), iOS may fail to resolve the
            // route — the NavigationLink fires but the destination handler
            // never matches. Hoisted to the Form level here.
            .navigationDestination(for: AccountNavTarget.self) { target in
                switch target {
                case .detail(let pubkey):
                    AccountDetailView(pubkeyHex: pubkey)
                }
            }
        }
    }

    // MARK: - Accounts (Stage C: replaces single-account "Signer Key" section)

    private var accountsSection: some View {
        Section("Accounts") {
            ForEach(appState.accounts) { account in
                NavigationLink(value: AccountNavTarget.detail(pubkey: account.pubkeyHex)) {
                    HStack(spacing: 12) {
                        accountAvatarSmall(for: account)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.displayLabel)
                                .font(.subheadline.bold())
                            Text(truncatedNpub(for: account))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if account.pubkeyHex == appState.currentAccount?.pubkeyHex {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        accountToDelete = account
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            Button {
                if appState.accounts.count >= Account.maxAccountsPerDevice {
                    showCapAlert = true
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                } else {
                    showAddSheet = true
                }
            } label: {
                Label("Add Account", systemImage: "plus.circle")
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddAccountSheet()
        }
        .alert("Account limit reached", isPresented: $showCapAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(AccountError.accountCapReached.errorDescription ?? "")
        }
        // Use the .alert(_:isPresented:presenting:actions:message:) overload —
        // the `presenting:` parameter captures the optional's value at
        // present-time and passes the unwrapped Account into the closures
        // by-value. Earlier code re-read `accountToDelete` inside the Delete
        // button action via `if let account = accountToDelete`, which silently
        // failed when SwiftUI's Binding-backed alert dismissal setter fired
        // mid-flight (triggered by Section re-renders from any appState.accounts
        // mutation: profile fetch landing, L1 wake, pull-to-refresh, etc.).
        // The captured `account` here survives even if accountToDelete is
        // nil'd by the setter — race eliminated.
        .alert(
            deleteAlertTitle,
            isPresented: Binding(
                get: { accountToDelete != nil },
                set: { if !$0 { accountToDelete = nil } }
            ),
            presenting: accountToDelete
        ) { account in
            Button("Delete", role: .destructive) {
                withAnimation {
                    appState.deleteAccount(pubkey: account.pubkeyHex)
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                }
                accountToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                accountToDelete = nil
            }
        } message: { _ in
            Text(deleteAlertMessage)
        }
    }

    // MARK: - Connections (cross-account bulk clear)

    /// Cross-account "Clear all connections" surface. Hidden when there are
    /// zero paired clients across all accounts (nothing to clear). Distinct
    /// from per-account clear (lives on AccountDetailView): this one wipes
    /// every pairing on the device in a single confirmation. Accounts
    /// themselves stay paired with this device.
    @ViewBuilder
    private var connectionsSection: some View {
        if totalConnectionCount > 0 {
            Section("Connections") {
                Button(role: .destructive) {
                    showClearAllConnectionsAlert = true
                } label: {
                    Label("Clear all connections for all accounts",
                          systemImage: "link.badge.minus")
                }
            }
            .alert("Clear all connections?",
                   isPresented: $showClearAllConnectionsAlert) {
                Button("Clear \(totalConnectionCount) connection\(totalConnectionCount == 1 ? "" : "s")",
                       role: .destructive) {
                    performClearAllConnections()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(clearAllConnectionsMessage)
            }
        }
    }

    /// Sum of paired clients across every account on this device. Drives
    /// both the section's visibility and the alert's count copy.
    private var totalConnectionCount: Int {
        appState.accounts.reduce(0) { total, account in
            total + SharedStorage.getConnectedClients(for: account.pubkeyHex).count
        }
    }

    /// Number of accounts that actually have at least one paired client —
    /// drives "X across N accounts" copy. An account with zero clients
    /// doesn't need to appear in the count phrasing.
    private var accountsWithConnectionsCount: Int {
        appState.accounts.filter {
            !SharedStorage.getConnectedClients(for: $0.pubkeyHex).isEmpty
        }.count
    }

    private var clearAllConnectionsMessage: String {
        let acrossClause = accountsWithConnectionsCount > 1
            ? " across \(accountsWithConnectionsCount) accounts"
            : ""
        return "Unpairs every connected client\(acrossClause). Paired apps will need to re-pair to keep signing. Accounts themselves stay on this device."
    }

    private func performClearAllConnections() {
        appState.clearAllClientsForAllAccounts()
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// Avatar treatment matches the Home strip / slim banner: cached PFP with
    /// opaque backing if available, AvatarView pubkey-hue fallback otherwise.
    /// Per design-system.md treatment A → B selection rule.
    @ViewBuilder
    private func accountAvatarSmall(for account: Account) -> some View {
        ZStack {
            if let img = cachedAvatar(for: account) {
                Color(.systemBackground)
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                AvatarView(pubkeyHex: account.pubkeyHex,
                           name: account.displayLabel,
                           size: 32)
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
    }

    /// Per-account cached profile image (same source as AccountStripView /
    /// SlimIdentityBar / AccountDetailView).
    private func cachedAvatar(for account: Account) -> UIImage? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConstants.appGroup
        ) else { return nil }
        let url = container.appendingPathComponent("cached-profile-\(account.pubkeyHex).dat")
        guard let data = try? Data(contentsOf: url),
              let img = UIImage(data: data) else { return nil }
        return img
    }

    private func truncatedNpub(for account: Account) -> String {
        let n = npubString(for: account)
        guard n.count > 20 else { return n }
        return String(n.prefix(12)) + "…" + String(n.suffix(6))
    }

    private func npubString(for account: Account) -> String {
        guard let pk = try? PublicKey.parse(publicKey: account.pubkeyHex) else {
            return account.pubkeyHex
        }
        return (try? pk.toBech32()) ?? account.pubkeyHex
    }

    private var deleteAlertTitle: String {
        let name = accountToDelete?.displayLabel ?? "this account"
        return "Delete @\(name)?"
    }

    private var deleteAlertMessage: String {
        guard let account = accountToDelete else { return "" }
        let pairs = SharedStorage.getConnectedClients(for: account.pubkeyHex).count
        let pairsClause = pairs == 0 ? "" : " and unpairs \(pairs) connection\(pairs == 1 ? "" : "s")"
        return "Permanently removes the key\(pairsClause). This cannot be undone."
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        Section("Permissions") {
            NavigationLink {
                ProtectedKindsEditor()
            } label: {
                HStack {
                    Text("Protected Event Kinds")
                    Spacer()
                    let count = SharedStorage.getProtectedKinds().count
                    Text("\(count) kinds")
                        .foregroundStyle(.secondary)
                }
            }

            Text("These event kinds require in-app approval for clients set to Medium Trust.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Push Proxy

    private var pushProxySection: some View {
        Section("Push Proxy") {
            TextField("Proxy URL", text: $proxyURL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(.body, design: .monospaced))
                .onSubmit {
                    SharedConstants.sharedDefaults.set(proxyURL, forKey: SharedConstants.proxyURLKey)
                }

            HStack {
                Text("Status")
                Spacer()
                let hasToken = !(SharedConstants.sharedDefaults.string(forKey: SharedConstants.deviceTokenKey) ?? "").isEmpty
                HStack(spacing: 4) {
                    Circle()
                        .fill(hasToken ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(hasToken ? "Registered" : "No token")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Register") {
                SharedConstants.sharedDefaults.set(proxyURL, forKey: SharedConstants.proxyURLKey)
                registrationStatus = "Registering..."
                appState.registerWithProxy { success, message in
                    registrationStatus = success ? "Registered ✓" : message
                }
            }

            if !registrationStatus.isEmpty {
                Text(registrationStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Relay

    private var relaySection: some View {
        Section("Relay") {
            HStack {
                Text(SharedConstants.relayURL)
                    .font(.system(.body, design: .monospaced))
                Spacer()
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                versionTapTimes.append(Date())
                // Keep only the most recent 10 to bound memory
                if versionTapTimes.count > 10 {
                    versionTapTimes = Array(versionTapTimes.suffix(10))
                }
                if DeveloperSettings.tapGateSatisfied(timestamps: versionTapTimes, window: 3.0, required: 7) {
                    if !devSettings.developerMenuUnlocked {
                        devSettings.developerMenuUnlocked = true
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                    versionTapTimes = []
                }
            }
        }
    }

    // MARK: - Developer

    private var developerSection: some View {
        Section("Developer") {
            Button {
                Task.detached(priority: .userInitiated) {
                    let entries = LogExporter.fetchRecentLogs(since: Date().addingTimeInterval(-3600))
                    let logs = LogExporter.format(entries: entries)
                    await MainActor.run {
                        UIPasteboard.general.string = logs.isEmpty ? "(no logs in the last hour)" : logs
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        showCopyLogsConfirmation = true
                    }
                }
            } label: {
                Label("Copy Recent Logs (last hour)", systemImage: "doc.on.clipboard")
            }

            Text("Captures Clave main-app logs only. NSE (signing) runs in a separate process and is not included — use Xcode Console for NSE logs.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            NavigationLink {
                L1DiagnosticsView()
            } label: {
                Label("L1 Diagnostics", systemImage: "waveform.circle")
            }

            NavigationLink {
                MultiAccountDiagnosticsView()
            } label: {
                Label("Multi-Account", systemImage: "person.2.circle")
            }

            Button {
                SharedStorage.setNeedsV3ExplainerCard()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                showReshowExplainerConfirmation = true
            } label: {
                Label("Re-show v3 explainer card", systemImage: "lock.shield")
            }

            Text("Sets the one-time card flag back to true. The card fires on next MainTabView appear — return to Home tab (cmd-shift-h on simulator) or relaunch to trigger.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button(role: .destructive) {
                devSettings.developerMenuUnlocked = false
                versionTapTimes = []
            } label: {
                Label("Lock Developer Menu", systemImage: "lock")
            }
        }
        .alert("Logs copied to clipboard", isPresented: $showCopyLogsConfirmation) {
            Button("OK", role: .cancel) {}
        }
        .alert("v3 explainer card flag set", isPresented: $showReshowExplainerConfirmation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The card fires on next MainTabView appear. Switch to Home tab or relaunch to trigger it.")
        }
    }

    private func loadSettings() {
        proxyURL = SharedConstants.sharedDefaults.string(forKey: SharedConstants.proxyURLKey)
            ?? SharedConstants.defaultProxyURL
    }
}
