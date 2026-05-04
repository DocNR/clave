import SwiftUI

/// Entry view for connecting a Nostr client. Shows three method cards
/// (Show my QR / Scan / Paste); each pushes its focused view via
/// NavigationStack. On a successful parse from any focused view, presents
/// ApprovalSheet over the navigation stack.
///
/// Per design-system.md: solid presentationBackground, no systemGray6
/// wrappers, theme-aware accents through ConnectAccountContextBar.
enum ConnectMethod: Hashable {
    case showQR
    case scanQR
    case paste
}

struct ConnectSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var path: [ConnectMethod] = []
    @State private var parsedURI: NostrConnectParser.ParsedURI?
    @State private var isConnecting = false
    @State private var connectionError: String?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 12) {
                    headerBlock
                    methodCards
                }
                .padding(.top, 8)
                .padding(.horizontal)
            }
            .navigationTitle("Connect Client")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: ConnectMethod.self) { method in
                switch method {
                case .showQR:
                    ConnectShowQRView()
                case .scanQR:
                    ConnectScanQRView(
                        onParsed: handleParsed,
                        onSwitchToPaste: { path = [.paste] }
                    )
                case .paste:
                    ConnectPasteView(onParsed: handleParsed)
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

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add a Nostr client")
                .font(.system(size: 22, weight: .bold))
            Text("Pick how your client wants to connect.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }

    private var methodCards: some View {
        VStack(spacing: 10) {
            ConnectMethodCard(
                iconSystemName: "qrcode",
                iconGradient: LinearGradient(
                    colors: [Color(red: 0.72, green: 0.52, blue: 1.00),
                             Color(red: 0.63, green: 0.30, blue: 1.00)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                title: "Show my QR",
                term: "(bunker)",
                subtitle: "Your client scans a code from Clave to connect.",
                onTap: { path = [.showQR] }
            )
            ConnectMethodCard(
                iconSystemName: "qrcode.viewfinder",
                iconGradient: LinearGradient(
                    colors: [Color(red: 0.30, green: 0.83, blue: 1.00),
                             Color(red: 0.18, green: 0.93, blue: 0.71)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                title: "Scan client's QR",
                term: "(Nostrconnect)",
                subtitle: "Point your camera at a code from a web client.",
                onTap: { path = [.scanQR] }
            )
            ConnectMethodCard(
                iconSystemName: "doc.on.clipboard",
                iconGradient: LinearGradient(
                    colors: [Color(red: 1.00, green: 0.60, blue: 0.40),
                             Color(red: 1.00, green: 0.42, blue: 0.61)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                title: "Paste Nostrconnect",
                term: nil,
                subtitle: "For clients on this same phone.",
                onTap: { path = [.paste] }
            )
        }
    }

    private var connectingOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("Connecting...")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func handleParsed(_ uri: NostrConnectParser.ParsedURI) {
        parsedURI = uri
    }

    private func submitApproval(uri: NostrConnectParser.ParsedURI,
                                permissions: ClientPermissions) {
        isConnecting = true
        connectionError = nil
        let captured = uri
        let capturedPerms = permissions
        parsedURI = nil
        Task {
            do {
                try await appState.handleNostrConnect(parsedURI: captured, permissions: capturedPerms)
                await MainActor.run {
                    isConnecting = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    connectionError = error.localizedDescription
                    isConnecting = false
                }
            }
        }
    }
}
