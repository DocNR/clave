import SwiftUI

/// Privacy overlay that covers a view when the app loses active focus
/// (`.inactive` or `.background` scenePhase). iOS captures the app-switcher
/// snapshot during `.inactive`, so any view rendering sensitive material
/// (nsec, bunker secret, QR code, incoming approval request) wraps itself
/// with `.snapshotProtected()` to prevent the snapshot from leaking it.
///
/// Audit ref: A10.1 in `~/hq/clave/security-audits/2026-04-17-pre-external-testflight.md`.
private struct SnapshotProtectedModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        ZStack {
            content
            if scenePhase != .active {
                privacyOverlay
            }
        }
    }

    private var privacyOverlay: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("Clave")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Hidden while inactive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension View {
    /// Hides the receiver behind a privacy overlay whenever scenePhase is not
    /// `.active` — primarily to prevent iOS app-switcher snapshots from
    /// capturing sensitive content. Apply to sheets that show secret keys,
    /// bunker URIs, QR codes, or incoming approval requests.
    func snapshotProtected() -> some View {
        modifier(SnapshotProtectedModifier())
    }
}
