import SwiftUI

/// Educational sheet shown from the Connect tab's help link. Explains the
/// difference between Nostrconnect and Bunker pairing, plus the same-device
/// gotcha where iOS can pause the other app's WebSocket while the user is
/// in Clave approving — which causes nostrconnect handshakes to fail
/// silently on same-device pairings.
///
/// Copy aims at users who don't already know the protocol — names the two
/// URI schemes by their literal prefix (`nostrconnect://`, `bunker://`) so
/// the strings users actually see in other apps are recognizable.
struct ConnectHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Clave supports two ways to pair with a Nostr app.")
                        .font(.body)

                    methodCard(
                        title: "Nostrconnect",
                        scheme: "nostrconnect://",
                        body: "The other app generates a code and shows it to you. You scan or paste it into Clave, pick which account to use, and approve. The app starts working immediately."
                    )

                    methodCard(
                        title: "Bunker",
                        scheme: "bunker://",
                        body: "Clave generates a code for one of your accounts. You copy it and paste it into the other app. The app uses Clave to sign on your behalf going forward."
                    )

                    sameDeviceCallout
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .navigationTitle("Nostrconnect vs Bunker")
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

    private func methodCard(title: String, scheme: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(scheme)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.tertiarySystemGroupedBackground), in: Capsule())
            }
            Text(body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var sameDeviceCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .foregroundStyle(.orange)
                Text("Same-device pairing")
                    .font(.subheadline.weight(.semibold))
            }
            Text("When the other app is on this same iPhone, prefer Bunker. With Nostrconnect, iOS may pause the other app's connection while you switch to Clave to approve — the handshake can fail silently. With Bunker, the other app initiates the connection at its own pace, so iOS doesn't interrupt it.")
                .font(.footnote)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

#Preview {
    Text("Tap to show")
        .sheet(isPresented: .constant(true)) {
            ConnectHelpSheet()
        }
}
