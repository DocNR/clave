import SwiftUI

/// Modal sheet for adding a new account. Three modes via segmented control:
///   • Generate  — random keypair.
///   • Paste     — user-supplied nsec or hex secret key.
///   • ncryptsec — NIP-49 encrypted secret key + password.
///
/// Paste/ncryptsec modes offer QR scanning for key QR codes (bare nsec,
/// `nostr:nsec1…`, ncryptsec1…, or hex). Reuses existing AppState methods
/// (generateAccount, addAccount). On success, the new account becomes
/// current automatically and the sheet dismisses with a toast confirmation
/// (toast wired in HomeView).
/// Profile identity (display name, username, etc.) is managed via clave.casa.
struct AddAccountSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable {
        case generate = "Generate new"
        case paste = "nsec / hex"
        case ncryptsec = "ncryptsec"
    }

    @State private var mode: Mode = .generate
    @State private var nsecInput: String = ""
    @State private var password: String = ""
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var showCapAlert = false
    @State private var showScanner = false
    @State private var scanPermissionDenied = false

    private var trimmedNsec: String {
        nsecInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Paste/scan normalization: NIP-19 URIs are often shared with a
    /// `nostr:` prefix, which Keys.parse rejects.
    private var normalizedSecret: String {
        var value = nsecInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("nostr:") {
            value = String(value.dropFirst("nostr:".count))
        }
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if mode != .generate {
                    Section("Private key") {
                        SecureField(
                            mode == .ncryptsec ? "ncryptsec1…" : "nsec1… or hex",
                            text: $nsecInput
                        )
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        if mode == .ncryptsec {
                            SecureField("Password", text: $password)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        Button {
                            scanPermissionDenied = false
                            showScanner = true
                        } label: {
                            Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section {
                    Button(action: performAdd) {
                        HStack {
                            Spacer()
                            if isWorking {
                                ProgressView()
                            } else {
                                Text(mode == .generate ? "Generate" : "Add")
                                    .font(.headline)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isWorking
                              || (mode != .generate && trimmedNsec.isEmpty)
                              || (mode == .ncryptsec && password.isEmpty))
                }
            }
            .navigationTitle("Add Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showScanner) {
                NavigationStack {
                    Group {
                        if scanPermissionDenied {
                            scanDeniedPlaceholder
                        } else {
                            QRScannerView(
                                isScanning: true,
                                onCode: handleScannedCode,
                                onPermissionDenied: { scanPermissionDenied = true }
                            )
                        }
                    }
                    .navigationTitle("Scan Key QR Code")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showScanner = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(.systemGroupedBackground))
        .alert("Account limit reached", isPresented: $showCapAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(AccountError.accountCapReached.errorDescription ?? "")
        }
    }

    private var scanDeniedPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Camera access denied")
                .font(.headline)
                .foregroundStyle(.secondary)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    /// Only accept QRs that carry a plausible secret key; anything else
    /// (npub, nostrconnect, note URIs) is ignored and scanning continues.
    private func handleScannedCode(_ code: String) {
        var value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("nostr:") {
            value = String(value.dropFirst("nostr:".count))
        }
        let isHexKey = value.count == 64 && value.allSatisfy { $0.isHexDigit }
        guard value.hasPrefix("nsec1") || value.hasPrefix("ncryptsec1") || isHexKey else {
            return
        }
        // Auto-route by prefix so a scanned ncryptsec lands in the mode
        // that shows the password field.
        mode = value.hasPrefix("ncryptsec1") ? .ncryptsec : .paste
        nsecInput = value
        showScanner = false
    }

    private func performAdd() {
        guard !isWorking else { return }
        // Pre-check for Generate; Paste defers to AppState's guard so
        // dedupe of existing accounts wins over the cap.
        if mode == .generate, appState.accounts.count >= Account.maxAccountsPerDevice {
            showCapAlert = true
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        // An ncryptsec pasted into the nsec/hex field: flip modes so the
        // password field appears instead of failing Keys.parse.
        if mode == .paste, normalizedSecret.hasPrefix("ncryptsec1") {
            mode = .ncryptsec
            errorMessage = nil
            return
        }
        errorMessage = nil
        isWorking = true

        do {
            switch mode {
            case .generate:
                _ = try appState.generateAccount()
            case .paste:
                _ = try appState.addAccount(nsec: normalizedSecret)
            case .ncryptsec:
                // NIP-49 passwords are arbitrary strings — pass raw, not
                // whitespace-trimmed.
                _ = try appState.addAccount(ncryptsec: normalizedSecret, password: password)
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch let error as AccountError where error == .accountCapReached {
            showCapAlert = true
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        } catch {
            errorMessage = "Could not add account: \(error.localizedDescription)"
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        isWorking = false
    }
}
