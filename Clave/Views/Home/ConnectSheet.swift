import SwiftUI

struct ConnectSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var nostrConnectInput = ""
    @State private var parseError: String?
    @State private var parsedURI: NostrConnectParser.ParsedURI?
    @State private var showApproval = false
    @State private var showQR = false
    @State private var copiedBunker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    bunkerSection
                    nostrConnectSection
                }
                .padding(.top, 16)
            }
            .navigationTitle("Connect Client")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showQR) {
                QRCodeView(content: appState.bunkerURI)
            }
        }
    }

    // MARK: - Bunker URI Section

    private var bunkerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Bunker Address")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    appState.rotateBunkerSecret()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } label: {
                    Label("New Secret", systemImage: "arrow.clockwise")
                        .font(.caption2)
                }
            }

            Text(appState.bunkerURI)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(3)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray6).opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = appState.bunkerURI
                    copiedBunker = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedBunker = false }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: copiedBunker ? "checkmark" : "doc.on.doc")
                        Text(copiedBunker ? "Copied" : "Copy")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(copiedBunker ? .green : .accentColor)

                Button {
                    showQR = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "qrcode")
                        Text("QR Code")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Text("Each secret is single-use. Tap New Secret to generate a fresh pairing link.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemGray6))
        }
        .padding(.horizontal)
    }

    // MARK: - Nostr Connect Section

    private var nostrConnectSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Or paste a nostrconnect:// URI")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("nostrconnect://...", text: $nostrConnectInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption2, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            if let parseError {
                Text(parseError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            Button {
                connectFromPaste()
            } label: {
                Text("Connect")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(nostrConnectInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemGray6))
        }
        .padding(.horizontal)
    }

    // MARK: - Actions

    private func connectFromPaste() {
        do {
            parsedURI = try NostrConnectParser.parse(nostrConnectInput.trimmingCharacters(in: .whitespacesAndNewlines))
            parseError = nil
            showApproval = true
        } catch let error as NostrConnectParser.ParseError {
            switch error {
            case .invalidScheme: parseError = "URI must start with nostrconnect://"
            case .missingPubkey: parseError = "Missing client public key"
            case .missingRelay: parseError = "Missing relay parameter"
            case .missingSecret: parseError = "Missing secret parameter"
            case .invalidURL: parseError = "Invalid URI format"
            }
        } catch {
            parseError = "Failed to parse URI"
        }
    }
}
