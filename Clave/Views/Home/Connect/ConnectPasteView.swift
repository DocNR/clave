import SwiftUI

/// Focused view for the "Paste Nostrconnect" connection method. User
/// pastes a `nostrconnect://` URI from a client on this same device.
/// On successful parse, the closure fires with the parsed URI; the parent
/// (ConnectSheet) presents ApprovalSheet.
struct ConnectPasteView: View {
    let onParsed: (NostrConnectParser.ParsedURI) -> Void

    @State private var input = ""
    @State private var parseError: String?

    private var trimmedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ConnectAccountContextBar()
                pasteCard
                connectButton
                helperText
            }
            .padding(.top, 8)
        }
        .navigationTitle("Paste Nostrconnect")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var pasteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nostrconnect URI")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $input)
                .font(.system(.caption2, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(minHeight: 80, maxHeight: 120)
                .padding(8)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if input.isEmpty {
                        Text("nostrconnect://...")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(16)
                            .allowsHitTesting(false)
                    }
                }

            Button {
                if let pasted = UIPasteboard.general.string {
                    input = pasted
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            } label: {
                Label("Paste from clipboard", systemImage: "doc.on.clipboard")
                    .font(.caption)
            }
            .buttonStyle(.bordered)

            if let parseError {
                Text(parseError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    private var connectButton: some View {
        Button {
            parseAndContinue()
        } label: {
            Text("Connect")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(trimmedInput.isEmpty)
        .padding(.horizontal)
    }

    private var helperText: some View {
        Text("For clients on this same phone — copy their `nostrconnect://` link and paste it here.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
    }

    private func parseAndContinue() {
        do {
            let parsed = try NostrConnectParser.parse(trimmedInput)
            parseError = nil
            onParsed(parsed)
        } catch let error as NostrConnectParser.ParseError {
            switch error {
            case .invalidScheme: parseError = "URI must start with nostrconnect://"
            case .missingPubkey: parseError = "Missing client public key"
            case .missingRelay:  parseError = "Missing relay parameter"
            case .missingSecret: parseError = "Missing secret parameter"
            case .invalidURL:    parseError = "Invalid URI format"
            }
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        } catch {
            parseError = "Failed to parse URI"
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}
