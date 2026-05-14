import SwiftUI

/// Unified account picker for all connect-time consent. Used by:
///   1. Phase 1 in-app NostrConnect flow (after URI parse, before ApprovalSheet)
///   2. Phase 1 in-app bunker flow (before URI render)
///   3. External nostrconnect:// deeplink flow (after URL routes in)
///
/// Mode `.single` is the only mode in Phase 1. Mode `.multi` lands in Phase 2
/// for multi-account NostrConnect. Auto-skips entirely when
/// `appState.accounts.count == 1` — the single account is auto-bound and the
/// picker never renders.
struct ConnectAccountPicker: View {

    enum Mode {
        case single   // bunker, single-NostrConnect, deeplink
        case multi    // Phase 2: NostrConnect with accounts=multi
    }

    /// Whether the picker should be entirely skipped given the user's account
    /// count. Caller pattern: check this BEFORE presenting the picker; if true,
    /// call onPick directly with the sole account's pubkey instead of rendering
    /// the picker UI.
    ///
    /// Skip when exactly 1 account exists (the single-account case where
    /// the picker would be a degenerate one-row sheet). Do NOT skip when 0
    /// accounts exist — the caller should route to onboarding rather than
    /// auto-binding to a non-existent account.
    static func shouldAutoSkip(accountCount: Int) -> Bool {
        accountCount == 1
    }

    /// Default selection set for `.multi` mode.
    /// Rules (matches spec §"ConnectAccountPicker — multi-select mode"):
    ///   - if total accounts ≤ 5: all non-capped accounts are pre-checked
    ///   - if total accounts > 5: none are pre-checked (deliberate selection)
    /// Capped accounts are NEVER pre-checked regardless of total count —
    /// surfacing them pre-selected would just create extra uncheck taps.
    static func defaultSelection(
        for pubkeys: [String],
        cappedSigners: Set<String>
    ) -> Set<String> {
        if pubkeys.count <= 5 {
            return Set(pubkeys).subtracting(cappedSigners)
        } else {
            return Set()
        }
    }

    /// Whether the Continue button is enabled — at least 1 account must
    /// be selected.
    static func canProceed(selectedCount: Int) -> Bool {
        selectedCount >= 1
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    let parsedURI: NostrConnectParser.ParsedURI?  // nil for bunker (no URI yet)
    let onPick: (_ pubkeys: [String]) -> Void

    @State private var multiModeSelectedPubkeys: Set<String> = []
    @State private var multiModeCappedSigners: Set<String> = []
    /// One-shot guard so `.onAppear` re-firing (parent re-render, navigation
    /// push/pop) does NOT clobber the user's hand-picked selection. The cap
    /// refresh still runs every appear — only the selection seed is gated.
    @State private var didInitMultiSelection: Bool = false
    /// Tracks which capped row's tap-hint is currently visible. Nil = no
    /// hint shown. Tapping a non-capped row (or the same capped row again)
    /// clears it. Per spec §"Cap pre-flight in the picker": tap on a capped
    /// row must surface a hint, not be silently swallowed.
    @State private var capHintForPubkey: String? = nil

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                headerBlock
                    .padding(.horizontal)
                    .padding(.top, 8)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(appState.accounts) { account in
                            accountRow(for: account)
                        }
                    }
                    .padding(.horizontal)
                }
                if case .multi = mode {
                    continueButton
                        .padding(.horizontal)
                        .padding(.bottom, 12)
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { setupMultiModeDefaults() }
        }
        .presentationBackground(Color(.systemGroupedBackground))
        .snapshotProtected()
    }

    private func setupMultiModeDefaults() {
        guard case .multi = mode else { return }
        // Always refresh capped signers — pair counts can change between
        // appearances (a user pairing another client in a different flow).
        multiModeCappedSigners = Set(
            appState.accounts
                .map(\.pubkeyHex)
                .filter { PairAccountCapInfo(
                    signerPubkey: $0,
                    currentPairCount: SharedStorage.pairCountForSigner($0)
                ).isAtCap }
        )
        // Only initialize selection the FIRST time — preserve user's
        // unchecks across .onAppear re-entries (which can fire if the
        // sheet's parent re-renders).
        guard !didInitMultiSelection else { return }
        multiModeSelectedPubkeys = Self.defaultSelection(
            for: appState.accounts.map(\.pubkeyHex),
            cappedSigners: multiModeCappedSigners
        )
        didInitMultiSelection = true
    }

    private var continueButton: some View {
        Button {
            onPick(Array(multiModeSelectedPubkeys))
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            dismiss()
        } label: {
            Text(continueLabel)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!Self.canProceed(selectedCount: multiModeSelectedPubkeys.count))
    }

    private var continueLabel: String {
        let n = multiModeSelectedPubkeys.count
        return "Continue with \(n) account\(n == 1 ? "" : "s")"
    }

    private var navigationTitle: String {
        switch mode {
        case .single: return "Connect with which account?"
        case .multi: return "Connect with which accounts?"
        }
    }

    private var headerBlock: some View {
        Text(headerText)
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
    }

    private var headerText: AttributedString {
        switch mode {
        case .single:
            // Phase 1 single-mode header — matches the original DeeplinkAccountPicker.
            var s = AttributedString("Choose the identity to use for ")
            var bold = AttributedString(clientLabel)
            bold.font = .system(size: 14, weight: .semibold)
            s.append(bold)
            s.append(AttributedString("."))
            return s
        case .multi:
            // Phase 2 multi-mode header.
            return AttributedString("\(clientLabel) wants to connect to multiple accounts.")
        }
    }

    private var clientLabel: String {
        parsedURI?.name ?? "this connection"
    }

    @ViewBuilder
    private func accountRow(for account: Account) -> some View {
        switch mode {
        case .single:
            singleModeRow(for: account)
        case .multi:
            multiModeRow(for: account)
        }
    }

    /// Single-mode: tap-to-pick (radio behavior). Tapping a row commits the
    /// selection and dismisses the sheet. The CURRENT account (the one
    /// active in the identity bar) is row-highlighted to match multi-mode's
    /// selection highlight — both modes use the same "tinted row + theme
    /// stroke" treatment so the picker reads consistently regardless of
    /// mode.
    private func singleModeRow(for account: Account) -> some View {
        let theme = AccountTheme.forAccount(pubkeyHex: account.pubkeyHex)
        let isCurrent = account.pubkeyHex == appState.currentAccount?.pubkeyHex
        return Button {
            onPick([account.pubkeyHex])
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            dismiss()
        } label: {
            HStack(spacing: 14) {
                accountAvatar(for: account)
                VStack(alignment: .leading, spacing: 3) {
                    Text("@\(account.displayLabel)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(truncatedNpub(account.pubkeyHex))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isCurrent {
                    Text("Current")
                        .font(.caption2.bold())
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(theme.start.opacity(0.15), in: Capsule())
                }
            }
            .padding(12)
            .background(rowBackground(theme: theme, highlighted: isCurrent))
        }
        .buttonStyle(.plain)
    }

    /// Multi-mode: tap-to-toggle (checkbox behavior). Capped rows render
    /// with a "5/5 clients" badge and dimmed visuals; tapping a capped row
    /// surfaces an inline hint (NOT silently swallowed — see spec §"Cap
    /// pre-flight in the picker"). Tapping a non-capped row toggles its
    /// membership in `multiModeSelectedPubkeys`; the sheet does NOT dismiss
    /// on row tap — dismissal happens via the Continue button at the bottom.
    private func multiModeRow(for account: Account) -> some View {
        let theme = AccountTheme.forAccount(pubkeyHex: account.pubkeyHex)
        let isSelected = multiModeSelectedPubkeys.contains(account.pubkeyHex)
        let isCapped = multiModeCappedSigners.contains(account.pubkeyHex)
        let showingCapHint = capHintForPubkey == account.pubkeyHex
        return Button {
            if isCapped {
                // Toggle the hint visibility for this row; clears hint on
                // any other row that might have been showing one.
                capHintForPubkey = showingCapHint ? nil : account.pubkeyHex
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } else {
                // Tapping a non-capped row clears any visible cap hint and
                // toggles selection.
                capHintForPubkey = nil
                toggleMultiSelection(account.pubkeyHex)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    accountAvatar(for: account)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("@\(account.displayLabel)")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(truncatedNpub(account.pubkeyHex))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isCapped {
                        Text("\(PairAccountCapInfo.cap)/\(PairAccountCapInfo.cap) clients")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(.tertiarySystemGroupedBackground), in: Capsule())
                    }
                }
                .opacity(isCapped ? 0.5 : 1.0)
                if showingCapHint {
                    Text("This account has \(PairAccountCapInfo.cap) paired clients. Revoke one in this account's settings to add another.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .padding(12)
            .background(rowBackground(theme: theme, highlighted: isSelected))
        }
        .buttonStyle(.plain)
    }

    /// Unified row background shared across `.single` (highlights the
    /// CURRENT account) and `.multi` (highlights SELECTED rows). When
    /// highlighted: per-account theme tint + accent-color stroke border;
    /// otherwise the default grouped-list background. This is the visual
    /// language consistency the picker was missing — every row, every
    /// mode, same selection-state treatment.
    @ViewBuilder
    private func rowBackground(theme: AccountTheme, highlighted: Bool) -> some View {
        if highlighted {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.start.opacity(0.18))
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(theme.accent.opacity(0.4), lineWidth: 1)
            }
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemGroupedBackground))
        }
    }

    private func toggleMultiSelection(_ pubkeyHex: String) {
        if multiModeSelectedPubkeys.contains(pubkeyHex) {
            multiModeSelectedPubkeys.remove(pubkeyHex)
        } else {
            multiModeSelectedPubkeys.insert(pubkeyHex)
        }
    }

    /// Account avatar reading the on-disk profile-picture cache
    /// (`cached-profile-<pubkey>.dat` in the app group). Falls back to
    /// gradient+initials when no cached image exists. Matches the pattern
    /// used in `AccountStripView`, `SettingsView`, and `SlimIdentityBar` —
    /// fixes the previous `AsyncImage(url:)` cache-miss flicker that
    /// rendered "default" on every sheet presentation.
    private func accountAvatar(for account: Account) -> some View {
        CachedAccountAvatarView(pubkeyHex: account.pubkeyHex,
                                displayLabel: account.displayLabel,
                                size: 60)
    }

    /// User-facing truncated npub for the picker subtitle. Falls back to
    /// the raw hex prefix only if encoding fails (shouldn't happen for a
    /// known account; defensive).
    private func truncatedNpub(_ pubkeyHex: String) -> String {
        guard let npub = try? Nip19.encodeNpub(pubkeyHex: pubkeyHex),
              npub.count > 16 else {
            return String(pubkeyHex.prefix(12)) + "…"
        }
        return "\(npub.prefix(12))…\(npub.suffix(4))"
    }
}
