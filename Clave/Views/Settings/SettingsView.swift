import SwiftUI
import LocalAuthentication

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showDeleteConfirmation = false
    @State private var showExportSheet = false
    @State private var proxyURL = ""
    @State private var registrationStatus = ""
    @State private var devSettings = DeveloperSettings.shared
    @State private var versionTapTimes: [Date] = []
    @State private var showCopyLogsConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                signerKeySection
                permissionsSection
                pushProxySection
                relaySection
                aboutSection
                if devSettings.developerMenuUnlocked {
                    developerSection
                }
            }
            .navigationTitle("Settings")
            .onAppear { loadSettings() }
            .alert("Delete Key", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    appState.deleteKey()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete your signer key from this device. All paired clients will be disconnected and will need a new bunker URI from the next key you import or generate. Make sure you have a backup of your current nsec.")
            }
            .sheet(isPresented: $showExportSheet) {
                ExportKeySheet()
            }
        }
    }

    // MARK: - Signer Key

    private var signerKeySection: some View {
        Section("Signer Key") {
            HStack {
                Text("npub")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
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

            Button {
                showExportSheet = true
            } label: {
                Label("Export Secret Key", systemImage: "key.horizontal")
            }

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete Key", systemImage: "trash")
            }
        }
    }

    private var truncatedNpub: String {
        let npub = appState.npub
        guard npub.count > 20 else { return npub }
        return String(npub.prefix(12)) + "..." + String(npub.suffix(6))
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
                let logs = LogExporter.format(
                    entries: LogExporter.fetchRecentLogs(since: Date().addingTimeInterval(-3600))
                )
                if logs.isEmpty {
                    UIPasteboard.general.string = "(no logs in the last hour)"
                } else {
                    UIPasteboard.general.string = logs
                }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showCopyLogsConfirmation = true
            } label: {
                Label("Copy Recent Logs (last hour)", systemImage: "doc.on.clipboard")
            }

            Text("Captures Clave main-app logs only. NSE (signing) runs in a separate process and is not included — use Xcode Console for NSE logs.")
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
    }

    private func loadSettings() {
        proxyURL = SharedConstants.sharedDefaults.string(forKey: SharedConstants.proxyURLKey)
            ?? SharedConstants.defaultProxyURL
    }
}
