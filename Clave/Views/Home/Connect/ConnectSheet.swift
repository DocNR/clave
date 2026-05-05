import SwiftUI

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
    @State private var isConnecting = false
    @State private var connectionError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
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
            ConnectNostrconnectTabView(onParsed: handleParsed)
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
