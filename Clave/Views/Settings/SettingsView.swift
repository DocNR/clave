import SwiftUI
import LocalAuthentication

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showAddSheet = false
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
                            Text(displayLabelInSettings(for: account))
                                .font(.subheadline.bold())
                            Text(truncatedPubkey(account.pubkeyHex))
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
            }
            Button {
                showAddSheet = true
            } label: {
                Label("Add Account", systemImage: "plus.circle")
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddAccountSheet()
        }
    }

    @ViewBuilder
    private func accountAvatarSmall(for account: Account) -> some View {
        let initial = String(displayLabelInSettings(for: account).first ?? "?").uppercased()
        let theme = AccountTheme.forAccount(pubkeyHex: account.pubkeyHex)
        ZStack {
            LinearGradient(colors: [theme.start, theme.end],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(initial)
                .font(.caption.bold())
                .foregroundStyle(.white)
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
    }

    private func displayLabelInSettings(for account: Account) -> String {
        if let p = account.petname, !p.isEmpty { return p }
        if let d = account.profile?.displayName, !d.isEmpty { return d }
        return String(account.pubkeyHex.prefix(8))
    }

    private func truncatedPubkey(_ hex: String) -> String {
        guard hex.count > 16 else { return hex }
        return String(hex.prefix(8)) + "…" + String(hex.suffix(4))
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
            Toggle(isOn: $devSettings.nostrconnectEnabled) {
                VStack(alignment: .leading) {
                    Text("Enable Nostrconnect")
                    Text("Experimental — some clients have compatibility issues. Use bunker:// for reliable signing.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

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
