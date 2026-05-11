import SwiftUI
import UIKit

/// Entry view for connecting a Nostr client. One sheet; segmented control
/// switches between Bunker (Clave shows a code to a client) and Nostrconnect
/// (a client shows a code to Clave). On a successful parse from either tab,
/// presents ApprovalSheet over the navigation stack.
///
/// Per design-system.md: solid presentationBackground, no systemGray6
/// wrappers, theme-aware accents through ConnectAccountContextBar.
///
/// Replaces the previous 3-card method chooser. See
/// docs/superpowers/specs/2026-05-04-connect-sheet-redesign-design.md.
struct ConnectSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private enum Tab: Hashable { case bunker, nostrconnect }

    @State private var selectedTab: Tab = .bunker
    @State private var parsedURI: NostrConnectParser.ParsedURI?
    /// Source of the most recent parsed URI. Drives the "Connecting…"
    /// overlay copy — paste implies same-device pairing (switch back to
    /// the client app), QR implies cross-device (stay in Clave). Default
    /// is overwritten by handleParsed before isConnecting ever flips.
    @State private var lastParsedSource: NostrConnectURISource = .paste
    @State private var isConnecting = false
    @State private var connectionError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Connection method", selection: $selectedTab) {
                    Text("Bunker").tag(Tab.bunker)
                    Text("Nostrconnect").tag(Tab.nostrconnect)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)

                ConnectAccountContextBar()

                tabBody
            }
            .navigationTitle("Connect Client")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $parsedURI) { uri in
                ApprovalSheet(parsedURI: uri) { permissions in
                    submitApproval(uri: uri, permissions: permissions)
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
        .presentationBackground(Color(.systemGroupedBackground))
        .snapshotProtected()
    }

    @ViewBuilder
    private var tabBody: some View {
        switch selectedTab {
        case .bunker:
            ConnectBunkerTabView()
        case .nostrconnect:
            ConnectNostrconnectTabView(parsedURI: parsedURI, onParsed: handleParsed)
        }
    }

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

    private func handleParsed(_ uri: NostrConnectParser.ParsedURI, source: NostrConnectURISource) {
        parsedURI = uri
        lastParsedSource = source
    }

    private func submitApproval(uri: NostrConnectParser.ParsedURI,
                                permissions: ClientPermissions) {
        isConnecting = true
        connectionError = nil
        let captured = uri
        let capturedPerms = permissions
        parsedURI = nil
        Task { @MainActor in
            // Extend foreground execution so the handshake survives the user
            // swiping to the client app mid-flight. Critical window is the
            // initial connect→ack→pair-client (~2-3s); after that NSE can
            // service follow-up RPCs via the proxy's secondary subscription.
            var bgTaskID: UIBackgroundTaskIdentifier = .invalid
            bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "nostrconnect-handshake") {
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                    bgTaskID = .invalid
                }
            }
            do {
                let signerPubkeys = [appState.currentAccount?.pubkeyHex ?? ""]
                _ = try await appState.handleNostrConnect(
                    parsedURI: captured,
                    signerPubkeys: signerPubkeys,
                    permissions: capturedPerms
                )
                isConnecting = false
                dismiss()
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
}
