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
    /// before the user had an account. Domain-first (the url's host is the
    /// largest, most trustworthy element; else the pubkey fingerprint — never
    /// the self-asserted name); the self-asserted name/icon are rendered small
    /// and explicitly marked unverified — brand-new users are the most
    /// phishable audience, so nothing self-asserted is given authority. Same
    /// rendering rules and strings as ApprovalSheet, via `CallerIdentity`.
    private func callerBanner(_ caller: NostrConnectParser.ParsedURI) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Same identity grammar as ClientIdentityHeader / ApprovalSheet:
            // the deterministic AvatarView for this client pubkey, so the
            // partner the user sees here is visibly the same one on the
            // ApprovalSheet a moment later.
            HStack(alignment: .center, spacing: 12) {
                callerAvatar(caller)

                VStack(alignment: .leading, spacing: 2) {
                    Text(callerHeadline(caller))
                        .font(callerHeadlineIsFingerprint(caller) ? .headline.monospaced() : .headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("wants to connect")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    // The claim truncates; the marker is a fixed sibling so
                    // a long name can never push "unverified" off screen.
                    if let claim = CallerIdentity.unverifiedClaim(name: caller.name, imageURL: caller.imageURL) {
                        HStack(spacing: 4) {
                            Text(claim)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(CallerIdentity.unverifiedMarker)
                                .fixedSize()
                                .layoutPriority(1)
                        }
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    }
                    // The fingerprint is already the headline when the caller
                    // gave no usable url — don't repeat it.
                    if !callerHeadlineIsFingerprint(caller) {
                        Text(truncatedPubkey(caller.clientPubkey))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
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
                    AvatarView(pubkeyHex: caller.clientPubkey, name: CallerIdentity.name(caller.name), size: 44)
                }
            }
        } else {
            AvatarView(pubkeyHex: caller.clientPubkey, name: CallerIdentity.name(caller.name), size: 44)
        }
    }

    /// Short client-pubkey fingerprint, same shape as `ClientIdentityHeader`.
    /// Delegates to `CallerIdentity` so this banner and ApprovalSheet share
    /// one implementation.
    private func truncatedPubkey(_ pubkey: String) -> String {
        CallerIdentity.fingerprint(pubkey)
    }

    /// Headline for the caller: the display host of its self-asserted `url`
    /// (full host minus a leading `www.`, ASCII-only), else the pubkey
    /// fingerprint — never the self-asserted name. Shared with ApprovalSheet
    /// via `CallerIdentity` so both surfaces render the same headline. Not a
    /// security boundary — a real verified-caller badge is a later
    /// well-known-JSON feature.
    private func callerHeadline(_ caller: NostrConnectParser.ParsedURI) -> String {
        CallerIdentity.headline(url: caller.url, pubkey: caller.clientPubkey)
    }

    /// Mirrors `ApprovalSheet.callerHeadlineIsFingerprint`: true when there is
    /// no usable url, so the separate fingerprint line is suppressed.
    private func callerHeadlineIsFingerprint(_ caller: NostrConnectParser.ParsedURI) -> Bool {
        CallerIdentity.domain(fromURL: caller.url) == nil
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
                // The app-icon mark, presented as an icon tile — the asset is
                // an opaque square, so it needs the rounded clip. Decorative:
                // the "Clave" wordmark right below carries the name.
                Image("ClaveLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 112, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
                    .accessibilityHidden(true)
                    .padding(.bottom, 8)

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
                    // Same card grammar as Home's stat tiles and the caller
                    // banner above: ultra-thin material in a 12pt rounded rect.
                    HStack(spacing: 10) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(.secondary)
                        TextField("nsec1... or hex secret key", text: $nsecInput)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(.body, design: .monospaced))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 24)

                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                // Same pair as ApprovalSheet's action buttons: full-width
                // prominent primary over a lighter secondary, both .large.
                Button {
                    importKey()
                } label: {
                    Text("Import Existing Key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.blue)
                .disabled(nsecInput.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.horizontal, 24)

                Button {
                    generateKey()
                } label: {
                    Text("Generate New Key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.horizontal, 24)
            }

            Spacer()
                .frame(height: 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(welcomeBackgroundGradient.ignoresSafeArea())
    }

    /// Ambient gradient behind the welcome step — the same stop recipe as
    /// HomeView's `homeBackgroundGradient`, so the first screen and Home read
    /// as one app. There is no account yet to derive a theme from, so this
    /// uses a fixed palette entry chosen to sit with the logo's deep blue.
    private var welcomeBackgroundGradient: some View {
        let theme = AccountTheme.palette[4]  // sky → navy
        return LinearGradient(
            stops: [
                .init(color: theme.start.opacity(0.42), location: 0.0),
                .init(color: theme.end.opacity(0.22), location: 0.35),
                .init(color: theme.end.opacity(0.10), location: 0.70),
                .init(color: theme.start.opacity(0.04), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
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
