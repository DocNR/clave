import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @State private var step = 1
    @State private var nsecInput = ""
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if step == 1 {
                    welcomeStep
                } else {
                    keySecuredStep
                }
            }
            .navigationBarHidden(true)
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.accentColor)

                Text("Clave")
                    .font(.largeTitle.bold())

                Text("Your Nostr keys, protected.")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Text("Sign from any app without exposing your nsec.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Spacer()

            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    TextField("nsec1... or hex secret key", text: $nsecInput)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 24)

                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Button {
                    importKey()
                } label: {
                    Text("Import Existing Key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(nsecInput.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.horizontal, 24)

                Button {
                    generateKey()
                } label: {
                    Text("Generate New Key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 24)
            }

            Spacer()
                .frame(height: 48)
        }
    }

    // MARK: - Step 2: Key Secured

    private var keySecuredStep: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)

                Text("Key Secured")
                    .font(.largeTitle.bold())

                Text("Your key is stored securely in the iOS Keychain.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            // npub display
            VStack(spacing: 8) {
                Text("Your public key")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(appState.npub)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 24)

                Button {
                    UIPasteboard.general.string = appState.npub
                } label: {
                    Label("Copy npub", systemImage: "doc.on.doc")
                        .font(.caption)
                }
            }

            // How it works
            VStack(alignment: .leading, spacing: 12) {
                Text("How it works")
                    .font(.headline)

                howItWorksRow(number: "1", text: "Copy your bunker URI from the Home screen")
                howItWorksRow(number: "2", text: "Paste it into any Nostr client")
                howItWorksRow(number: "3", text: "Clave signs events in the background via push notifications")
            }
            .padding(.horizontal, 32)

            Spacer()

            Button {
                appState.registerWithProxy()
            } label: {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)

            Spacer()
                .frame(height: 48)
        }
    }

    private func howItWorksRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.bold())
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func importKey() {
        do {
            try appState.importKey(nsec: nsecInput)
            errorMessage = ""
            nsecInput = ""
            step = 2
        } catch {
            errorMessage = "Invalid key: \(error.localizedDescription)"
        }
    }

    private func generateKey() {
        do {
            try appState.generateKey()
            errorMessage = ""
            step = 2
        } catch {
            errorMessage = "Generation failed: \(error.localizedDescription)"
        }
    }
}
