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

    var body: some View {
        NavigationStack {
            Form {
                accountsSection
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
        .alert(deleteAlertTitle, isPresented: Binding(
            get: { accountToDelete != nil },
            set: { if !$0 { accountToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let account = accountToDelete {
                    withAnimation {
                        appState.deleteAccount(pubkey: account.pubkeyHex)
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    }
                }
                accountToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                accountToDelete = nil
            }
        } message: {
            Text(deleteAlertMessage)
        }
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
    }

    private func loadSettings() {
        proxyURL = SharedConstants.sharedDefaults.string(forKey: SharedConstants.proxyURLKey)
            ?? SharedConstants.defaultProxyURL
    }
}
