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
    @State private var showPicker = false
    @State private var pickedSignerPubkey: String?
    @State private var isConnecting = false
    @State private var connectionError: String?
    @State private var pushBunker = false
    @State private var approvalContext: ApprovalContext?

    private struct ApprovalContext: Identifiable {
        let id: String   // composite of URI id + signer pubkey
        let parsedURI: NostrConnectParser.ParsedURI
        let signerPubkey: String
    }

    var body: some View {
        NavigationStack {
            ConnectNostrConnectSurface(
                parsedURI: parsedURI,
                onParsed: handleParsed,
                onShowBunker: { pushBunker = true }
            )
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $pushBunker) {
                ConnectBunkerView()
            }
            .sheet(isPresented: $showPicker) {
                if let parsed = parsedURI {
                    ConnectAccountPicker(mode: .single, parsedURI: parsed) { pubkeys in
                        pickedSignerPubkey = pubkeys.first
                        showPicker = false
                        presentApproval()
                    }
                }
            }
            .sheet(item: $approvalContext) { ctx in
                ApprovalSheet(parsedURI: ctx.parsedURI,
                              boundAccountPubkey: ctx.signerPubkey) { permissions in
                    submitApproval(uri: ctx.parsedURI,
                                   signerPubkey: ctx.signerPubkey,
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

    private func handleParsed(_ uri: NostrConnectParser.ParsedURI, source: NostrConnectURISource) {
        parsedURI = uri
        lastParsedSource = source

        // Auto-skip picker when only 1 account exists.
        if ConnectAccountPicker.shouldAutoSkip(accountCount: appState.accounts.count),
           let only = appState.accounts.first {
            pickedSignerPubkey = only.pubkeyHex
            presentApproval()
        } else {
            showPicker = true
        }
    }

    private func presentApproval() {
        guard let uri = parsedURI, let signer = pickedSignerPubkey else { return }
        approvalContext = ApprovalContext(
            id: uri.id + ":" + signer,
            parsedURI: uri,
            signerPubkey: signer
        )
    }

    private func submitApproval(uri: NostrConnectParser.ParsedURI,
                                signerPubkey: String,
                                permissions: ClientPermissions) {
        isConnecting = true
        connectionError = nil
        approvalContext = nil
        parsedURI = nil
        pickedSignerPubkey = nil

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
                    signerPubkeys: [signerPubkey],
                    permissions: permissions
                )
                isConnecting = false
                if result.isAllFailure {
                    connectionError = result.failed.first?.errorMessage ?? "Unknown error"
                }
                // Success-only and partial cases dismiss naturally for single-mode
                // (partial-failure UX lands in Phase 2 with multi-mode).
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
