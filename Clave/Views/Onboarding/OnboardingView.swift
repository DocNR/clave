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
            .onAppear { appState.refreshOnboardingBanner() }
        }
    }

    // MARK: - Caller banner (Sign in with Clave, brand-new-user path)

    /// The "who is asking" banner shown when a partner connect URI was stashed
    /// before the user had an account. Domain-first (the registrable domain is
    /// the largest, most trustworthy element); the self-asserted name/icon are
    /// rendered small and explicitly marked unverified — brand-new users are
    /// the most phishable audience, so nothing self-asserted is given
    /// authority. Same rendering posture as ApprovalSheet.
    private func callerBanner(_ caller: NostrConnectParser.ParsedURI) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Same identity grammar as ClientIdentityHeader / ApprovalSheet:
            // the deterministic AvatarView for this client pubkey, so the
            // partner the user sees here is visibly the same one on the
            // ApprovalSheet a moment later.
            HStack(alignment: .center, spacing: 12) {
                callerAvatar(caller)

                VStack(alignment: .leading, spacing: 2) {
                    Text(callerDomain(caller))
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("wants to connect")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let name = caller.name, !name.isEmpty {
                        Text("calls itself “\(name)” · unverified")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(truncatedPubkey(caller.clientPubkey))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Text("Create or import your key to continue.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Same rules as ApprovalSheet's client header: show the partner's
    /// self-asserted `image` when the URI carries one, else the deterministic
    /// avatar for its pubkey. Kept small and paired with the "unverified"
    /// caption — the icon is self-asserted and carries no authority.
    @ViewBuilder
    private func callerAvatar(_ caller: NostrConnectParser.ParsedURI) -> some View {
        if let imageURLString = caller.imageURL,
           let url = URL(string: imageURLString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                default:
                    AvatarView(pubkeyHex: caller.clientPubkey, name: caller.name, size: 44)
                }
            }
        } else {
            AvatarView(pubkeyHex: caller.clientPubkey, name: caller.name, size: 44)
        }
    }

    /// Short client-pubkey fingerprint, same shape as `ClientIdentityHeader`.
    private func truncatedPubkey(_ pubkey: String) -> String {
        guard pubkey.count > 12 else { return pubkey }
        return String(pubkey.prefix(8)) + "…" + String(pubkey.suffix(4))
    }

    /// Registrable domain of the caller's self-asserted `url`, for the
    /// domain-first line. Strips a leading `www.`; falls back to the
    /// self-asserted name (still unverified) or a generic label when no `url`
    /// is present. Not a security boundary — a real verified-caller badge is a
    /// later well-known-JSON feature.
    private func callerDomain(_ caller: NostrConnectParser.ParsedURI) -> String {
        if let urlString = caller.url,
           let host = URL(string: urlString)?.host,
           !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        if let name = caller.name, !name.isEmpty {
            return name
        }
        return "A Nostr app"
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 32) {
            if let caller = appState.onboardingConnectBanner {
                callerBanner(caller)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
            }

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
            try appState.importKey(nsec: nsecInput, source: .onboardingImport)
            errorMessage = ""
            nsecInput = ""
            step = 2
        } catch {
            errorMessage = "Invalid key: \(error.localizedDescription)"
        }
    }

    private func generateKey() {
        do {
            try appState.generateKey(source: .onboardingGenerate)
            errorMessage = ""
            step = 2
        } catch {
            errorMessage = "Generation failed: \(error.localizedDescription)"
        }
    }
}
