import SwiftUI

/// Discover tab — stub for Phase 1. Will eventually surface NIP-46-compatible
/// Nostr clients with one-tap pairing flows (Damus, Yakihonne, Stacker.news,
/// nostrudel, Tableau, etc.). For now, a friendly placeholder.
struct DiscoverView: View {

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "safari")
                    .font(.system(size: 64))
                    .foregroundStyle(.tertiary)

                VStack(spacing: 8) {
                    Text("Discover")
                        .font(.title2.weight(.semibold))
                    Text("Find Nostr apps that work with Clave.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Text("Coming soon")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(.tertiarySystemGroupedBackground), in: Capsule())

                Spacer()
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .navigationTitle("Discover")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
