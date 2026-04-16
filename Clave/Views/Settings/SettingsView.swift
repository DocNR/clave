import SwiftUI
import LocalAuthentication

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showDeleteConfirmation = false
    @State private var showExportSheet = false
    @State private var proxyURL = ""
    @State private var registrationStatus = ""

    var body: some View {
        NavigationStack {
            Form {
                signerKeySection
                permissionsSection
                pushProxySection
                relaySection
                aboutSection
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
        }
    }

    private func loadSettings() {
        proxyURL = SharedConstants.sharedDefaults.string(forKey: SharedConstants.proxyURLKey)
            ?? SharedConstants.defaultProxyURL
    }
}
