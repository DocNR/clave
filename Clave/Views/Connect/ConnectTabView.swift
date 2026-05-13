import SwiftUI
import UIKit

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
    @State private var lastParsedSource: NostrConnectURISource = .paste
    @State private var showPicker = false           // single-mode picker
    @State private var showMultiPicker = false      // multi-mode picker
    @State private var pickedSignerPubkeys: [String] = []
    @State private var isConnecting = false
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
                              boundAccountPubkeys: ctx.signerPubkeys) { permissions in
                    submitApproval(uri: ctx.parsedURI,
                                   signerPubkeys: ctx.signerPubkeys,
                                   permissions: permissions)
                }
            }
            .overlay {
                if isConnecting { connectingOverlay }
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

    private func handleParsed(_ uri: NostrConnectParser.ParsedURI, source: NostrConnectURISource) {
        parsedURI = uri
        lastParsedSource = source

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

    private func submitApproval(uri: NostrConnectParser.ParsedURI,
                                signerPubkeys: [String],
                                permissions: ClientPermissions) {
        isConnecting = true
        connectionError = nil
        approvalContext = nil
        parsedURI = nil
        pickedSignerPubkeys = []

        Task { @MainActor in
            // Extend foreground execution so the handshake survives the user
            // swiping to the client app mid-flight (build-62 bg-task pattern).
            // Critical window is the initial connect→ack→pair-client (~2-3s);
            // after that NSE can service follow-up RPCs via the proxy's
            // secondary subscription.
            var bgTaskID: UIBackgroundTaskIdentifier = .invalid
            bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "nostrconnect-handshake") {
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                    bgTaskID = .invalid
                }
            }
            do {
                let result = try await appState.handleNostrConnect(
                    parsedURI: uri,
                    signerPubkeys: signerPubkeys,
                    permissions: permissions
                )
                handleHandshakeResult(result)
            } catch {
                connectionError = error.localizedDescription
                isConnecting = false
            }
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
        }
    }

    private func handleHandshakeResult(_ result: HandshakeResult) {
        isConnecting = false
        if result.isAllFailure {
            connectionError = result.failed.first?.errorMessage ?? "Unknown error"
        }
        // All-success: sheet was already dismissed in submitApproval (approvalContext = nil).
        // Partial-failure: Task 11 will route this case back through ApprovalSheet's
        // result view; for Phase 2 / Task 9, we just don't surface an error alert.
    }

    // MARK: - Connecting overlay (lifted from the deleted ConnectSheet)

    private var connectingOverlay: some View {
        // Same-device (paste): the client app is on this device but iOS
        // suspends its WebSocket subscription as soon as it loses
        // foreground, so the user must switch back to it for the client
        // to receive Clave's connect-response. UIBackgroundTask in
        // submitApproval keeps Clave running for the ~15s handshake
        // window. Cross-device (QR): there's no client app to return to
        // on this device, so the original "stay in Clave" copy applies.
        let subtitle: String = switch lastParsedSource {
        case .paste:
            "Switch back to your client app to finish connecting. Clave keeps running in the background."
        case .qrScan:
            "Stay in Clave for a few seconds"
        }
        return ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                VStack(spacing: 6) {
                    Text("Connecting...")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
