import SwiftUI

/// Static explanatory sheet shown when the user taps the
/// "What's a nostrconnect URI?" help link on the Nostrconnect tab.
/// Uses presentationDetents([.medium]) so it covers the bottom half
/// of the screen without dismissing the parent ConnectSheet.
///
/// Copy intentionally avoids jargon beyond `nostrconnect://` itself —
/// that's the literal string users need to recognize. Includes a
/// "what happens next" so users know pasting doesn't auto-commit.
struct ConnectHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("If a Nostr app or website asks you to \"connect a remote signer,\" they'll show you a code starting with nostrconnect://.")
                        .font(.body)
                    Text("Paste or scan that code here. Clave will ask you to approve the connection.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .navigationTitle("What's a nostrconnect URI?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(.systemGroupedBackground))
    }
}

#Preview {
    Text("Tap to show")
        .sheet(isPresented: .constant(true)) {
            ConnectHelpSheet()
        }
}
