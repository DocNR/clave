import SwiftUI

/// Modal sheet for adding a new account. Two modes via segmented control:
///   • Generate — random keypair.
///   • Paste    — user-supplied nsec.
///
/// Reuses existing AppState methods (generateAccount, addAccount). On
/// success, the new account becomes current automatically and the sheet
/// dismisses with a toast confirmation (toast wired in HomeView).
/// Profile identity (display name, username, etc.) is managed via clave.casa.
struct AddAccountSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable {
        case generate = "Generate new"
        case paste = "Paste nsec"
    }

    @State private var mode: Mode = .generate
    @State private var nsecInput: String = ""
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var showCapAlert = false

    private var trimmedNsec: String {
        nsecInput.trimmingCharacters(in: .whitespacesAndNewlines)
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

                if mode == .paste {
                    Section("Private key") {
                        SecureField("nsec1…", text: $nsecInput)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
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
                    .disabled(isWorking || (mode == .paste && trimmedNsec.isEmpty))
                }
            }
            .navigationTitle("Add Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
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

    private func performAdd() {
        guard !isWorking else { return }
        // Pre-check for Generate; Paste-nsec defers to AppState's guard so
        // dedupe of existing accounts wins over the cap.
        if mode == .generate, appState.accounts.count >= Account.maxAccountsPerDevice {
            showCapAlert = true
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        errorMessage = nil
        isWorking = true

        do {
            switch mode {
            case .generate:
                _ = try appState.generateAccount(petname: nil)
            case .paste:
                _ = try appState.addAccount(nsec: trimmedNsec, petname: nil)
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
