import SwiftUI
import NostrSDK

/// Per-account detail screen. Reachable from:
///   • AccountStripView active-pill tap (Task 2)
///   • AccountStripView long-press on any pill (Task 2, via pendingDetailPubkey)
///   • SettingsView Accounts section row tap (Task 6)
///
/// Skeleton in this task: gradient banner header + petname rename + delete.
/// Profile section + rotate-bunker + export-key + refresh-profile come in
/// Task 5.
struct AccountDetailView: View {
    let pubkeyHex: String

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var petnameInput: String = ""
    @State private var showDeleteAlert = false
    @State private var showRotateBunkerAlert = false
    @State private var showExportSheet = false

    /// The Account this view is for. Reads from appState.accounts each time
    /// (auto-updates on rename / delete). nil if account was deleted while
    /// viewing — view dismisses on appearance of nil.
    private var account: Account? {
        appState.accounts.first { $0.pubkeyHex == pubkeyHex }
    }

    var body: some View {
        Form {
            // Banner appears as the first section's "header" so it gets
            // full-bleed treatment in Form / List. SwiftUI Form drops list
            // padding for clear sections we render manually.
            Section {
                EmptyView()
            } header: {
                if let account {
                    bannerHeader(for: account)
                        .listRowInsets(EdgeInsets())
                        .textCase(nil)
                }
            }

            if account != nil {
                petnameSection
                profileSection
                securitySection
                deleteSection
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            petnameInput = account?.petname ?? ""
        }
        .onChange(of: account == nil) { _, isNil in
            if isNil { dismiss() }
        }
        .alert("Delete \(deleteAlertNameSnippet)?",
               isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteAlertMessage)
        }
        .alert("Rotate bunker secret for \(deleteAlertNameSnippet)?",
               isPresented: $showRotateBunkerAlert) {
            Button("Rotate") { performRotateBunker() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Generates a new bunker URI for this account. Existing pairings continue working.")
        }
        .sheet(isPresented: $showExportSheet) {
            ExportKeySheet()
        }
    }

    // MARK: - Banner

    @ViewBuilder
    private func bannerHeader(for account: Account) -> some View {
        let theme = AccountTheme.forAccount(pubkeyHex: account.pubkeyHex)
        ZStack(alignment: .leading) {
            LinearGradient(
                colors: [theme.start, theme.end],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            HStack(spacing: 14) {
                avatarLarge(for: account)
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.displayLabel)
                        .font(.title3).fontWeight(.bold)
                        .foregroundStyle(.white)
                    Text(truncatedNpub(for: account))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                copyNpubButton(for: account)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 22)
        }
    }

    private func avatarLarge(for account: Account) -> some View {
        let initial = String(account.displayLabel.first ?? "?").uppercased()
        return ZStack {
            if let img = cachedAvatar(for: account) {
                // Opaque backing so PFPs with transparent backgrounds (robohash,
                // some kind:0 avatars) don't bleed the banner's theme gradient
                // through the image.
                Color(.systemBackground)
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.22)
                Text(initial)
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 2))
    }

    /// Per-account cached profile image (same source as AccountStripView and
    /// SlimIdentityBar). Synchronous read on each body evaluation; files are
    /// small (~50KB) so the cost is negligible.
    private func cachedAvatar(for account: Account) -> UIImage? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConstants.appGroup
        ) else { return nil }
        let url = container.appendingPathComponent("cached-profile-\(account.pubkeyHex).dat")
        guard let data = try? Data(contentsOf: url),
              let img = UIImage(data: data) else { return nil }
        return img
    }

    private func copyNpubButton(for account: Account) -> some View {
        Button {
            UIPasteboard.general.string = npubString(for: account)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(8)
                .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Petname

    private var petnameSection: some View {
        Section("Petname") {
            TextField("Display label", text: $petnameInput)
                .autocorrectionDisabled()
            if let account, petnameInput.trimmingCharacters(in: .whitespacesAndNewlines) != (account.petname ?? "") {
                Button("Save Petname") {
                    let trimmed = petnameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    appState.renamePetname(for: account.pubkeyHex,
                                            to: trimmed.isEmpty ? nil : trimmed)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
        }
    }

    // MARK: - Profile

    @ViewBuilder
    private var profileSection: some View {
        if let account {
            Section("Profile") {
                if let profile = account.profile,
                   let name = profile.displayName, !name.isEmpty {
                    LabeledContent("Display name", value: name)
                } else {
                    Text("No profile published. Tap Refresh to fetch.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button {
                    appState.refreshProfile(for: account.pubkeyHex)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Label("Refresh profile", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    // MARK: - Security

    private var securitySection: some View {
        Section("Security") {
            if let account {
                Button {
                    showRotateBunkerAlert = true
                } label: {
                    Label("Rotate bunker secret", systemImage: "arrow.triangle.2.circlepath")
                }

                // Export only available for the CURRENT account (existing
                // ExportKeySheet uses the current keychain entry).
                if account.pubkeyHex == appState.currentAccount?.pubkeyHex {
                    Button {
                        showExportSheet = true
                    } label: {
                        Label("Export private key", systemImage: "key.viewfinder")
                    }
                }
            }
        }
    }

    private func performRotateBunker() {
        guard let account else { return }
        _ = SharedStorage.rotateBunkerSecret(for: account.pubkeyHex)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: - Delete

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteAlert = true
            } label: {
                Label("Delete Account", systemImage: "trash")
            }
        } footer: {
            Text("Deletes the private key from this device and unpairs all clients on this account. This cannot be undone — back up your nsec first if you may need it later.")
                .font(.caption)
        }
    }

    private var deleteAlertNameSnippet: String {
        guard let account else { return "this account" }
        return "@\(account.displayLabel)"
    }

    private var deleteAlertMessage: String {
        guard let account else { return "" }
        let pairs = SharedStorage.getConnectedClients(for: account.pubkeyHex).count
        let pairsClause = pairs == 0 ? "" : " and unpairs \(pairs) connection\(pairs == 1 ? "" : "s")"
        return "Permanently removes the key\(pairsClause). This cannot be undone."
    }

    private func performDelete() {
        guard let account else { return }
        appState.deleteAccount(pubkey: account.pubkeyHex)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        // dismissal happens via .onChange(of: account == nil) above
    }

    // MARK: - Helpers

    private func npubString(for account: Account) -> String {
        guard let pk = try? PublicKey.parse(publicKey: account.pubkeyHex) else {
            return account.pubkeyHex
        }
        return (try? pk.toBech32()) ?? account.pubkeyHex
    }

    private func truncatedNpub(for account: Account) -> String {
        let n = npubString(for: account)
        guard n.count > 24 else { return n }
        return String(n.prefix(14)) + "…" + String(n.suffix(8))
    }
}
