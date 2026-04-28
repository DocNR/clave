import SwiftUI
import LocalAuthentication

struct ExportKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var nsec: String?
    @State private var authError = ""
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                if let nsec {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.orange)

                        Text("Secret Key")
                            .font(.title2.bold())

                        Text("Never share this with anyone. Anyone with this key can sign events as you.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)

                        Text(nsec)
                            .font(.system(.caption, design: .monospaced))
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal, 24)
                            .textSelection(.enabled)

                        Button {
                            // Local-only + 120s expiration: avoid Universal Clipboard syncing
                            // the nsec to other Apple devices, and auto-clear after 2 minutes so
                            // it doesn't sit in the pasteboard indefinitely (audit finding A10.2).
                            UIPasteboard.general.setItems(
                                [["public.utf8-plain-text": nsec]],
                                options: [
                                    .localOnly: true,
                                    .expirationDate: Date().addingTimeInterval(120)
                                ]
                            )
                            copied = true
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                        } label: {
                            Label(copied ? "Copied" : "Copy to Clipboard", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(copied ? .green : .orange)
                        .padding(.horizontal, 24)
                    }
                } else if !authError.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "faceid")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text(authError)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Try Again") { authenticate() }
                            .buttonStyle(.bordered)
                    }
                } else {
                    ProgressView("Authenticating...")
                }

                Spacer()
            }
            .navigationTitle("Export Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { authenticate() }
        }
        .snapshotProtected()
    }

    private func authenticate() {
        let context = LAContext()
        var error: NSError?

        // Try biometrics first, fall back to device passcode
        let policy: LAPolicy = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication

        // Delay to avoid crashing during sheet presentation animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if context.canEvaluatePolicy(policy, error: nil) {
                context.evaluatePolicy(
                    policy,
                    localizedReason: "Authenticate to view your secret key"
                ) { success, authenticationError in
                    DispatchQueue.main.async {
                        if success {
                            nsec = SharedKeychain.loadNsec()
                        } else {
                            authError = authenticationError?.localizedDescription ?? "Authentication failed"
                        }
                    }
                }
            } else {
                // No authentication available at all — show key directly
                nsec = SharedKeychain.loadNsec()
            }
        }
    }
}
