import SwiftUI

/// One-time explainer card shown after the v3 schema-version migration
/// wipes existing `ClientPermissions` grants. Mounted at `MainTabView`
/// level and gated by `SharedStorage.needsV3ExplainerCard()` — the flag
/// is set by the migration that runs at app boot
/// (`AppState.runPermissionsSchemaMigrationIfNeeded`, see commit
/// `ac86d8b`) and cleared by tapping "Got it" here.
///
/// Goal: prepare the user for the next-request re-grant prompts so they
/// don't feel like a regression. Accounts + client pairs are
/// intentionally preserved across the migration; only `ClientPermissions`
/// is wiped. See report Decision #1 ("Permission storage strategy") and
/// risk 1.1 in the implementation report.
struct V3ExplainerCardView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)

            Text("Clearer permission prompts")
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                Text("Clave can now show you what apps are doing on your behalf in much more detail.")
                    .multilineTextAlignment(.center)

                Text("You'll be asked to re-grant permissions for your connected apps the next time they make a request. Your accounts and app connections are unchanged.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .font(.body)
            .padding(.horizontal, 8)

            Spacer()

            Button {
                SharedStorage.clearV3ExplainerCardFlag()
                dismiss()
            } label: {
                Text("Got it")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .interactiveDismissDisabled()
    }
}
