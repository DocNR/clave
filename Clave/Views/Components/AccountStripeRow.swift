import SwiftUI

/// Compact "On account" row used in both `PendingRequestDetailView` and
/// `ActivityDetailView`. Shows a vertical theme-stripe (matches the
/// per-account gradient identity from `AccountStripView` / Home) next
/// to the account's display label.
///
/// Caller is responsible for the multi-account visibility check
/// (`appState.accounts.count > 1`) — single-account users should see
/// no account context at all (no row, no enclosing Section header),
/// and the call site has the structural context to skip both.
///
/// Pass the request's / entry's stored `signerPubkeyHex` directly —
/// the helper falls back to `appState.signerPubkeyHex` for legacy rows
/// (empty-string sentinels from before Task 3 of multi-account sprint).
struct AccountStripeRow: View {
    let signerPubkeyHex: String
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(themeGradient)
                .frame(width: 4, height: 22)
            Text(label)
                .font(.body)
        }
    }

    private var resolvedPubkey: String {
        signerPubkeyHex.isEmpty ? appState.signerPubkeyHex : signerPubkeyHex
    }

    private var label: String {
        appState.accounts.first(where: { $0.pubkeyHex == resolvedPubkey })?.displayLabel
            ?? String(resolvedPubkey.prefix(8))
    }

    private var themeGradient: LinearGradient {
        let theme = AccountTheme.forAccount(pubkeyHex: resolvedPubkey)
        return LinearGradient(
            colors: [theme.start, theme.end],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
