import SwiftUI
import NostrSDK

/// Per-account detail screen. Reachable from:
///   • AccountStripView active-pill tap
///   • AccountStripView long-press on any pill (via pendingDetailPubkey)
///   • SettingsView Accounts section row tap
///
/// Visual direction (per docs/superpowers/specs/2026-05-03-account-detail-view-redesign-design.md):
/// identity-zone banner extends Home's per-account theme; body Form sits on
/// Home's ambient gradient with .scrollContentBackground(.hidden). Section
/// headers use sentence-case .headline + .textCase(nil) to match Home's
/// "Connected Clients" treatment.
struct AccountDetailView: View {
    let pubkeyHex: String

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var petnameInput: String = ""
    @State private var showDeleteAlert = false
    @State private var showRotateBunkerAlert = false
    @State private var showExportSheet = false
    @State private var isAboutExpanded: Bool = false

    /// The Account this view is for. Reads from appState.accounts each time
    /// so rename / delete from elsewhere update the view live. nil if account
    /// was deleted while viewing — view dismisses on appearance of nil.
    private var account: Account? {
        appState.accounts.first { $0.pubkeyHex == pubkeyHex }
    }

    /// Per-account theme. Defensive fallback to palette[0] if account is nil
    /// mid-render so the gradient never disappears.
    private var theme: AccountTheme {
        if let account {
            return AccountTheme.forAccount(pubkeyHex: account.pubkeyHex)
        }
        return AccountTheme.palette[0]
    }

    var body: some View {
        Form {
            // Banner appears as the first section's "header" so it gets
            // full-bleed treatment in Form. SwiftUI Form drops list padding
            // for clear sections we render manually.
            Section {
                EmptyView()
            } header: {
                if let account {
                    bannerHeader(for: account)
                        .listRowInsets(EdgeInsets())
                        .textCase(nil)
                }
            }
            .listRowBackground(Color.clear)

            if account != nil {
                petnameSection
                profileSection
                securitySection
                deleteSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(ambientGradient.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.3), value: appState.currentAccount?.pubkeyHex)
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            guard let pubkey = account?.pubkeyHex else { return }
            await appState.refreshProfileAsync(for: pubkey)
        }
        .onAppear {
            petnameInput = account?.petname ?? ""
        }
        .onChange(of: account == nil) { _, isNil in
            if isNil { dismiss() }
        }
        .onChange(of: account?.profile?.about) { _, _ in
            // Reset expansion when the bio changes (account switch, pull-to-
            // refresh updating the cached profile). Prevents stale-state cases
            // where a long bio was expanded, then the next bio is short and
            // the toggle pill disappears but lineLimit(nil) is still applied.
            isAboutExpanded = false
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

    // MARK: - Ambient gradient

    private var ambientGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: theme.start.opacity(0.42), location: 0.0),
                .init(color: theme.end.opacity(0.22),   location: 0.30),
                .init(color: theme.end.opacity(0.10),   location: 0.60),
                .init(color: theme.start.opacity(0.04), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Banner

    @ViewBuilder
    private func bannerHeader(for account: Account) -> some View {
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
        Section {
            TextField("Display label", text: $petnameInput)
                .autocorrectionDisabled()
                .listRowBackground(Color.clear)
            if let account, petnameInput.trimmingCharacters(in: .whitespacesAndNewlines) != (account.petname ?? "") {
                Button("Save Petname") {
                    let trimmed = petnameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    appState.renamePetname(for: account.pubkeyHex,
                                            to: trimmed.isEmpty ? nil : trimmed)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                .listRowBackground(Color.clear)
            }
        } header: {
            Text("Petname")
                .font(.headline)
                .foregroundStyle(.primary)
                .textCase(nil)
        }
    }

    // MARK: - Profile (extended in Tasks 5-7)

    @ViewBuilder
    private var profileSection: some View {
        if let account {
            Section {
                // Display name (kv-row, conditional on data)
                if let displayName = account.profile?.displayName, !displayName.isEmpty {
                    LabeledContent("Display name", value: displayName)
                        .listRowBackground(Color.clear)
                }

                // About (stacked block, .lineLimit(2) default with tap-to-expand)
                if let about = account.profile?.about, !about.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("About")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                        Text(about)
                            .foregroundStyle(.primary)
                            .font(.body)
                            .lineLimit(isAboutExpanded ? nil : 2)
                        if aboutOverflowsCap {
                            Text(isAboutExpanded ? "Show less" : "Show more")
                                .foregroundStyle(theme.accent)
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard aboutOverflowsCap else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isAboutExpanded.toggle()
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    .listRowBackground(Color.clear)
                }

                // NIP-05 (kv-row, conditional on data)
                if let nip05 = account.profile?.nip05, !nip05.isEmpty {
                    LabeledContent("NIP-05", value: nip05)
                        .listRowBackground(Color.clear)
                }

                // Lightning (lud16, kv-row monospaced, conditional on data)
                if let lud16 = account.profile?.lud16, !lud16.isEmpty {
                    LabeledContent("Lightning") {
                        Text(lud16)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.primary)
                    }
                    .listRowBackground(Color.clear)
                }

                // Paired-clients stat (always shown)
                HStack {
                    Text("\(connectionCount) paired client\(connectionCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .listRowBackground(Color.clear)

                // Edit on clave.casa (always visible, outbound)
                Button {
                    openClaveCasaEditor()
                } label: {
                    HStack {
                        Label("Edit on clave.casa", systemImage: "person.text.rectangle")
                            .foregroundStyle(theme.accent)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(theme.accent.opacity(0.7))
                            .font(.caption)
                    }
                }
                .listRowBackground(Color.clear)

                // Empty-state hint when no profile is cached at all
                if profileIsEmpty {
                    Text("No profile published. Pull down to refresh.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .listRowBackground(Color.clear)
                }
            } header: {
                Text("Profile")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }
        }
    }

    private var connectionCount: Int {
        guard let account else { return 0 }
        return SharedStorage.getConnectedClients(for: account.pubkeyHex).count
    }

    /// Heuristic for "About text likely overflows two lines on iPhone".
    /// True text-measurement via PreferenceKey is overkill for v0.2.0 —
    /// this approximate threshold avoids the extra view-tree work.
    /// Future: swap to GeometryReader-based measurement if false positives/
    /// negatives become a real problem on device (BACKLOG item).
    private var aboutOverflowsCap: Bool {
        (account?.profile?.about?.count ?? 0) > 80
    }

    /// True when the profile cache has no user-meaningful content. Used to
    /// gate the "No profile published. Pull down to refresh." hint so it
    /// only shows when there is genuinely nothing to display. Future content
    /// fields should slot in here rather than expand the inline condition at
    /// the use site.
    private var profileIsEmpty: Bool {
        guard let profile = account?.profile else { return true }
        return (profile.displayName?.isEmpty ?? true)
            && (profile.about?.isEmpty ?? true)
            && (profile.nip05?.isEmpty ?? true)
            && (profile.lud16?.isEmpty ?? true)
    }

    // MARK: - Security

    private var securitySection: some View {
        Section {
            if let account {
                Button {
                    showRotateBunkerAlert = true
                } label: {
                    Label("Rotate bunker secret", systemImage: "arrow.triangle.2.circlepath")
                }
                .listRowBackground(Color.clear)

                if account.pubkeyHex == appState.currentAccount?.pubkeyHex {
                    Button {
                        showExportSheet = true
                    } label: {
                        Label("Export private key", systemImage: "key.viewfinder")
                    }
                    .listRowBackground(Color.clear)
                }
            }
        } header: {
            Text("Security")
                .font(.headline)
                .foregroundStyle(.primary)
                .textCase(nil)
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
            .listRowBackground(Color.clear)
        } footer: {
            Text("Deletes the private key from this device and unpairs all clients on this account. This cannot be undone — back up your nsec first if you may need it later.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var deleteAlertNameSnippet: String {
        guard let account else { return "this account" }
        return "@\(account.displayLabel)"
    }

    private var deleteAlertMessage: String {
        let pairsClause = connectionCount == 0
            ? ""
            : " and unpairs \(connectionCount) connection\(connectionCount == 1 ? "" : "s")"
        return "Permanently removes the key\(pairsClause). This cannot be undone."
    }

    private func performDelete() {
        guard let account else { return }
        appState.deleteAccount(pubkey: account.pubkeyHex)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        // Dismissal happens via .onChange(of: account == nil) in body — once
        // appState.accounts no longer contains this pubkey, the computed
        // `account` returns nil and the onChange modifier triggers dismiss().
    }

    /// Opens clave.casa's kind:0 editor with this account's bunker URI
    /// pre-bound via URL fragment (never reaches a server).
    /// clave.casa parses the fragment client-side and either re-uses an existing
    /// pairing for this signer pubkey (skip handshake) or pairs fresh.
    private func openClaveCasaEditor() {
        guard let account else { return }
        guard let bunkerURI = appState.bunkerURI(for: account.pubkeyHex) else {
            return
        }
        guard let encoded = bunkerURI.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) else {
            return
        }
        let urlString = "\(SharedConstants.claveCasaEditBaseURL)#bunker=\(encoded)"
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
