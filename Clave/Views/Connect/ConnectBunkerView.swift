import SwiftUI

/// Bunker child route inside the Connect tab. Presents `ConnectAccountPicker`
/// first (when N >= 2) so the user explicitly chooses which account's bunker
/// URI to share. When N == 1, auto-skips the picker and renders directly.
///
/// Flow:
///   1. onAppear → check account count
///   2a. N == 1 → auto-bind to the sole account; render BunkerURIRender
///   2b. N >= 2 → show ConnectAccountPicker sheet; user picks; render BunkerURIRender
///   3. BunkerURIRender shows QR + URI text + Copy / New secret for the
///      explicitly selected signer (never implicitly currentAccount)
struct ConnectBunkerView: View {

    @Environment(AppState.self) private var appState

    @State private var pickedSignerPubkey: String?
    @State private var showPicker = false

    var body: some View {
        Group {
            if let signer = pickedSignerPubkey {
                BunkerURIRender(signerPubkey: signer)
            } else {
                Color.clear
                    .onAppear { presentOrAutoSkip() }
                    .sheet(isPresented: $showPicker) {
                        ConnectAccountPicker(mode: .single, parsedURI: nil) { pubkeys in
                            pickedSignerPubkey = pubkeys.first
                            showPicker = false
                        }
                    }
            }
        }
        .navigationTitle("Share Bunker Code")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Private

    private func presentOrAutoSkip() {
        if ConnectAccountPicker.shouldAutoSkip(accountCount: appState.accounts.count),
           let only = appState.accounts.first {
            pickedSignerPubkey = only.pubkeyHex
        } else {
            showPicker = true
        }
    }
}
