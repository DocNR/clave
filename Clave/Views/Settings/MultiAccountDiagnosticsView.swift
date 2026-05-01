import SwiftUI
import Security

/// Developer diagnostics for the multi-account sprint (Stage B).
/// Reachable from Settings → Developer (after the 7-tap unlock).
///
/// Three jobs:
/// 1. Read-only inspector of multi-account state (accounts list, per-signer
///    dicts, legacy-key presence). Surfaces migration health at a glance.
/// 2. Test fixture for exercising AppState's account lifecycle without
///    waiting for the Stage C UI sprint — generate test accounts, switch
///    between them, delete them, all using the real production code paths.
/// 3. Plumbing-verification harness for end-to-end testing on internal
///    TestFlight against the test proxy (`proxy-test.clave.casa`).
///
/// Stage C will replace this with a real account picker UX. This view
/// stays as a dev tool.
struct MultiAccountDiagnosticsView: View {
    @Environment(AppState.self) private var appState
    @State private var refreshTick = 0  // bump to force re-evaluation of legacy-key checks
    @State private var pendingDeletePubkey: String?
    @State private var copyConfirmation: String?

    var body: some View {
        Form {
            currentAccountSection
            accountsListSection
            testActionsSection
            migrationDiagnosticsSection
            l1BindingSection
        }
        .navigationTitle("Multi-Account")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "Delete account?",
            isPresented: Binding(
                get: { pendingDeletePubkey != nil },
                set: { if !$0 { pendingDeletePubkey = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let pk = pendingDeletePubkey {
                    appState.deleteAccount(pubkey: pk)
                    refreshTick += 1
                }
                pendingDeletePubkey = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletePubkey = nil
            }
        } message: {
            Text("If you didn't save your private key, it will be irretrievably lost. This will also unpair all clients connected to this account.")
        }
        .alert(
            "Copied",
            isPresented: Binding(
                get: { copyConfirmation != nil },
                set: { if !$0 { copyConfirmation = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(copyConfirmation ?? "")
        }
    }

    // MARK: - Current account

    private var currentAccountSection: some View {
        Section("Current account") {
            if let current = appState.currentAccount {
                labeled("pubkey", value: truncated(current.pubkeyHex))
                labeled("petname", value: current.petname ?? "—")
                labeled("profile name", value: current.profile?.displayName ?? "—")
                labeled("added at", value: dateString(current.addedAt))
                Button {
                    UIPasteboard.general.string = current.pubkeyHex
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    copyConfirmation = "Pubkey hex copied"
                } label: {
                    Label("Copy pubkey hex", systemImage: "doc.on.doc")
                }
            } else {
                Text("No current account")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - All accounts list

    private var accountsListSection: some View {
        Section("All accounts (\(appState.accounts.count))") {
            if appState.accounts.isEmpty {
                Text("—")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appState.accounts) { account in
                    accountRow(account)
                }
            }
        }
    }

    @ViewBuilder
    private func accountRow(_ account: Account) -> some View {
        let isCurrent = appState.currentAccount?.pubkeyHex == account.pubkeyHex
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
                Text(account.petname ?? account.profile?.displayName ?? truncated(account.pubkeyHex))
                    .font(.footnote.bold())
                Spacer()
            }
            Text(truncated(account.pubkeyHex))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if !isCurrent {
                    Button("Switch") {
                        appState.switchToAccount(pubkey: account.pubkeyHex)
                        refreshTick += 1
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                Button("Delete", role: .destructive) {
                    pendingDeletePubkey = account.pubkeyHex
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Test actions

    private var testActionsSection: some View {
        Section("Test actions") {
            Button {
                generateTestAccount()
            } label: {
                Label("Generate test account", systemImage: "plus.circle")
            }

            Button {
                appState.fetchProfileIfNeeded()
                copyConfirmation = "Profile fetch started — check back in a few seconds"
            } label: {
                Label("Refresh profile (current)", systemImage: "arrow.clockwise")
            }
            .disabled(appState.currentAccount == nil)

            Button {
                appState.rotateBunkerSecret()
                refreshTick += 1
                copyConfirmation = "Bunker secret rotated for current account"
            } label: {
                Label("Rotate bunker secret (current)", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(appState.currentAccount == nil)

            Text("Generated test accounts use a random keypair and auto-register with the configured proxy. Delete them via the row buttons above when done.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func generateTestAccount() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let petname = "Test \(formatter.string(from: Date()))"
        do {
            _ = try appState.generateAccount(petname: petname)
            refreshTick += 1
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            copyConfirmation = "Generate failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Migration diagnostics

    private var migrationDiagnosticsSection: some View {
        Section("Migration diagnostics") {
            // accountsKey state
            labeled("accountsKey", value: accountsKeyState)
            labeled("currentSignerPubkeyHex", value: truncated(currentSignerPubkeyHex))

            // Per-signer dict counts
            labeled("bunkerSecrets", value: dictCount(SharedConstants.bunkerSecretsKey))
            labeled("lastContactSets", value: dictCount(SharedConstants.lastContactSetsKey))
            labeled("lastRegisterTimes", value: dictCount(SharedConstants.lastRegisterTimesKey))

            // Legacy keys — should ALL be 0 post-Task-8
            legacyKeyRow("Legacy bunkerSecretKey", present: hasLegacyString(SharedConstants.bunkerSecretKey))
            legacyKeyRow("Legacy lastContactSetKey", present: hasLegacyData(SharedConstants.lastContactSetKey))
            legacyKeyRow("Legacy lastRegisterSucceededAtKey", present: hasLegacyDouble(SharedConstants.lastRegisterSucceededAtKey))
            legacyKeyRow("Legacy lastRegisterFailedAtKey", present: hasLegacyDouble(SharedConstants.lastRegisterFailedAtKey))
            legacyKeyRow("Legacy cachedProfileKey", present: hasLegacyData(SharedConstants.cachedProfileKey))
            legacyKeyRow("Legacy Keychain entry (signer-nsec)", present: SharedKeychain.loadNsec() != nil)

            // Keychain pubkey count
            labeled("Keychain pubkey count", value: "\(SharedKeychain.listAllPubkeys().count)")

            Text("Legacy keys should all read \"absent\" after Task 8 migration. Any \"present\" rows indicate cross-version cleanup is still pending — try restarting the app once.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        // Force re-evaluation on refreshTick changes
        .id(refreshTick)
    }

    @ViewBuilder
    private func legacyKeyRow(_ label: String, present: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(present ? "PRESENT" : "absent")
                .font(.footnote.bold())
                .foregroundStyle(present ? .red : .secondary)
        }
    }

    // MARK: - L1 binding

    private var l1BindingSection: some View {
        Section("L1 foreground sub") {
            let l1Pubkey = ForegroundRelaySubscription.shared.currentRelays.isEmpty
                ? "(not started)"
                : truncated(SharedConstants.sharedDefaults.string(forKey: SharedConstants.currentSignerPubkeyHexKey) ?? "")
            labeled("Bound to", value: l1Pubkey)
            labeled("State", value: ForegroundRelaySubscription.shared.state.rawValue)

            Text("L1 in v1 binds to the current account at start time. Switching account during a foreground session does NOT auto-restart L1 — restart from the L1 Diagnostics view if needed.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Helpers

    private var accountsKeyState: String {
        guard let data = SharedConstants.sharedDefaults.data(forKey: SharedConstants.accountsKey) else {
            return "absent"
        }
        return "\(data.count) bytes"
    }

    private var currentSignerPubkeyHex: String {
        SharedConstants.sharedDefaults.string(forKey: SharedConstants.currentSignerPubkeyHexKey) ?? ""
    }

    private func dictCount(_ key: String) -> String {
        guard let data = SharedConstants.sharedDefaults.data(forKey: key) else {
            return "absent"
        }
        // Both [String:String] and [String:[String]] and [String:[String:Double]]
        // share the same outer JSON shape; we just need the top-level key count.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "(invalid)"
        }
        return "\(json.count) signers"
    }

    private func hasLegacyString(_ key: String) -> Bool {
        guard let s = SharedConstants.sharedDefaults.string(forKey: key) else { return false }
        return !s.isEmpty
    }

    private func hasLegacyData(_ key: String) -> Bool {
        SharedConstants.sharedDefaults.data(forKey: key) != nil
    }

    private func hasLegacyDouble(_ key: String) -> Bool {
        SharedConstants.sharedDefaults.double(forKey: key) > 0
    }

    private func truncated(_ hex: String) -> String {
        guard hex.count > 16 else { return hex.isEmpty ? "—" : hex }
        return String(hex.prefix(8)) + "…" + String(hex.suffix(8))
    }

    private func dateString(_ ts: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: ts))
    }

    @ViewBuilder
    private func labeled(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.footnote)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
