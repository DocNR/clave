import SwiftUI

/// Modal sheet for adding a new account. Two modes via segmented control:
///   • Generate — random keypair, optional petname.
///   • Paste    — user-supplied nsec, optional petname.
///
/// Reuses existing AppState methods (generateAccount, addAccount). On
/// success, the new account becomes current automatically and the sheet
/// dismisses with a toast confirmation (toast wired in HomeView).
struct AddAccountSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable {
        case generate = "Generate new"
        case paste = "Paste nsec"
    }

    @State private var mode: Mode = .generate
    @State private var nsecInput: String = ""
    @State private var petnameInput: String = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

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

                Section("Petname (optional)") {
                    TextField("e.g. Personal", text: $petnameInput)
                        .autocorrectionDisabled()
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
    }

    private func performAdd() {
        guard !isWorking else { return }
        errorMessage = nil
        isWorking = true
        let petname = petnameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let petnameOrNil = petname.isEmpty ? nil : petname

        do {
            switch mode {
            case .generate:
                _ = try appState.generateAccount(petname: petnameOrNil)
            case .paste:
                _ = try appState.addAccount(nsec: trimmedNsec, petname: petnameOrNil)
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch {
            errorMessage = "Could not add account: \(error.localizedDescription)"
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        isWorking = false
    }
}
