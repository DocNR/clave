import SwiftUI

/// Root view for the Connect tab — Phase 1 of multi-account NostrConnect.
/// Replaces the previous ConnectSheet (deleted in Task 11) and the
/// "Connect a Client" button on HomeView (removed in Task 9).
///
/// Information architecture: Connect is cross-account. The picker step
/// (ConnectAccountPicker) is where the user explicitly chooses which
/// account they're pairing under. Replaces the implicit identity-bar
/// binding that the old ConnectSheet used.
struct ConnectTabView: View {

    @Environment(AppState.self) private var appState

    @State private var parsedURI: NostrConnectParser.ParsedURI?
    @State private var showPicker = false           // single-mode picker
    @State private var showMultiPicker = false      // multi-mode picker
    @State private var pickedSignerPubkeys: [String] = []
    @State private var connectionError: String?
    @State private var bunkerSignerPubkey: String?
    @State private var showBunkerPicker = false
    @State private var approvalContext: ApprovalContext?

    private struct ApprovalContext: Identifiable {
        let id: String   // composite of URI id + joined signer pubkeys
        let parsedURI: NostrConnectParser.ParsedURI
        let signerPubkeys: [String]
    }

    var body: some View {
        NavigationStack {
            ConnectNostrConnectSurface(
                parsedURI: parsedURI,
                onParsed: handleParsed,
                onShowBunker: handleShowBunker
            )
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $bunkerSignerPubkey) { signerPubkey in
                BunkerURIRender(signerPubkey: signerPubkey)
                    .navigationTitle("Share Bunker Code")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .sheet(isPresented: $showBunkerPicker) {
                ConnectAccountPicker(mode: .single, parsedURI: nil) { pubkeys in
                    showBunkerPicker = false
                    if let picked = pubkeys.first {
                        // Defer setting nav state so picker sheet finishes dismissing first
                        DispatchQueue.main.async {
                            bunkerSignerPubkey = picked
                        }
                    }
                }
            }
            .sheet(isPresented: $showPicker) {
                if let parsed = parsedURI {
                    ConnectAccountPicker(mode: .single, parsedURI: parsed) { pubkeys in
                        // .single always yields a 1-element array
                        pickedSignerPubkeys = pubkeys
                        showPicker = false
                        presentApproval()
                    }
                }
            }
            .sheet(isPresented: $showMultiPicker) {
                if let parsed = parsedURI {
                    ConnectAccountPicker(mode: .multi, parsedURI: parsed) { pubkeys in
                        pickedSignerPubkeys = pubkeys
                        showMultiPicker = false
                        if !pubkeys.isEmpty {
                            presentApproval()
                        }
                    }
                }
            }
            .sheet(item: $approvalContext) { ctx in
                ApprovalSheet(parsedURI: ctx.parsedURI,
                              boundAccountPubkeys: ctx.signerPubkeys) { result in
                    handleHandshakeCompletion(result, context: ctx)
                }
            }
            .alert("Connection Failed", isPresented: .init(
                get: { connectionError != nil },
                set: { if !$0 { connectionError = nil } }
            )) {
                Button("OK") { connectionError = nil }
            } message: {
                Text(connectionError ?? "Unknown error")
            }
        }
    }

    // MARK: - State machine

    private func handleShowBunker() {
        if ConnectAccountPicker.shouldAutoSkip(accountCount: appState.accounts.count),
           let only = appState.accounts.first {
            bunkerSignerPubkey = only.pubkeyHex
        } else {
            showBunkerPicker = true
        }
    }

    private func handleParsed(_ uri: NostrConnectParser.ParsedURI,
                              source _: NostrConnectURISource) {
        // `source` (paste/qrScan) used to drive copy in the now-removed
        // ConnectTabView.connectingOverlay. Connect progress now renders
        // inside ApprovalSheet (Task 10), which uses a single copy variant
        // independent of how the URI arrived.
        parsedURI = uri

        // Auto-skip picker when only 1 account exists — even multi-aware URIs
        // collapse to a one-element flow when N=1.
        if ConnectAccountPicker.shouldAutoSkip(accountCount: appState.accounts.count),
           let only = appState.accounts.first {
            pickedSignerPubkeys = [only.pubkeyHex]
            presentApproval()
        } else if uri.isMultiAccount {
            // Multi-account picker (Phase 2)
            showMultiPicker = true
        } else {
            // Single-account picker (Phase 1 path)
            showPicker = true
        }
    }

    private func presentApproval() {
        guard let uri = parsedURI, !pickedSignerPubkeys.isEmpty else { return }
        approvalContext = ApprovalContext(
            id: uri.id + ":" + pickedSignerPubkeys.joined(separator: ","),
            parsedURI: uri,
            signerPubkeys: pickedSignerPubkeys
        )
    }

    /// Routes the handshake outcome reported by ApprovalSheet's
    /// `onCompletion`. The sheet now runs the handshake itself (Task 10
    /// contract change), so the parent's job is reduced to deciding
    /// dismiss + error surfacing.
    ///
    /// - all-success: dismiss sheet, clear staged state.
    /// - all-failure: dismiss sheet, surface error via alert.
    /// - partial: leave sheet open so Task 11 can render the result view.
    ///   For Task 10 (this commit) the sheet just sits in its current
    ///   isConnecting=false post-loop state with a placeholder; Task 11
    ///   layers in the per-row final state + Done button.
    private func handleHandshakeCompletion(_ result: HandshakeResult,
                                           context: ApprovalContext) {
        if result.isAllSuccess {
            approvalContext = nil
            parsedURI = nil
            pickedSignerPubkeys = []
        } else if result.isAllFailure {
            approvalContext = nil
            parsedURI = nil
            pickedSignerPubkeys = []
            connectionError = result.failed.first?.errorMessage ?? "Unknown error"
        }
        // Partial-failure: keep approvalContext set. ApprovalSheet's
        // handshakeCompleted latch holds the post-loop placeholder UI in
        // place (per-row state, no Approve button) until Task 11 layers
        // in the full result view + Done button.
    }
}
