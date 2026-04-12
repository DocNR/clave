import SwiftUI
import NostrSDK

struct ContentView: View {
    @State private var nsecInput = ""
    @State private var signerPubkey = ""
    @State private var deviceToken = ""
    @State private var statusMessage = ""
    @State private var isKeyImported = false
    @State private var proxyURL = "http://localhost:3000"

    var bunkerURI: String {
        guard !signerPubkey.isEmpty else { return "" }
        let relay = SharedConstants.relayURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? SharedConstants.relayURL
        return "bunker://\(signerPubkey)?relay=\(relay)"
    }

    var body: some View {
        NavigationStack {
            Form {
                if isKeyImported {
                    // Bunker URI — the main thing users need
                    Section("Bunker Connection") {
                        Text(bunkerURI)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy Bunker URI") {
                            UIPasteboard.general.string = bunkerURI
                            statusMessage = "Bunker URI copied"
                        }
                        Text("Paste this into any NIP-46 compatible client to connect.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Section("Signer Key") {
                        HStack {
                            Text("Pubkey:")
                                .font(.caption)
                            Spacer()
                            Text(signerPubkey.prefix(16) + "...")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Button("Copy Full Pubkey") {
                            UIPasteboard.general.string = signerPubkey
                            statusMessage = "Pubkey copied"
                        }
                        Button("Delete Key", role: .destructive) {
                            deleteKey()
                        }
                    }

                    Section("Push Proxy") {
                        TextField("Proxy URL", text: $proxyURL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Register with Proxy") {
                            // Save proxy URL for auto-registration on future launches
                            SharedConstants.sharedDefaults.set(proxyURL, forKey: SharedConstants.proxyURLKey)
                            registerWithProxy()
                        }
                        if !deviceToken.isEmpty {
                            HStack {
                                Text("Token:")
                                    .font(.caption)
                                Spacer()
                                Text(deviceToken.prefix(16) + "...")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Text("No device token yet")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Section("Setup") {
                        Text("Import or generate a Nostr key to get started.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        TextField("nsec1... or hex secret key", text: $nsecInput)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Import Key") {
                            importKey()
                        }

                        Divider()

                        Button("Generate New Key") {
                            generateKey()
                        }
                    }
                }

                Section("Relay") {
                    Text(SharedConstants.relayURL)
                        .font(.caption)
                }

                if !statusMessage.isEmpty {
                    Section {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Clave")
        }
        .onAppear { loadState() }
    }

    private func loadState() {
        if let nsec = SharedKeychain.loadNsec(),
           let keys = try? Keys.parse(secretKey: nsec) {
            signerPubkey = keys.publicKey().toHex()
            isKeyImported = true
        }
        deviceToken = SharedConstants.sharedDefaults.string(
            forKey: SharedConstants.deviceTokenKey
        ) ?? ""
        if let savedProxy = SharedConstants.sharedDefaults.string(forKey: SharedConstants.proxyURLKey), !savedProxy.isEmpty {
            proxyURL = savedProxy
        }
    }

    private func importKey() {
        do {
            let keys = try Keys.parse(secretKey: nsecInput.trimmingCharacters(in: .whitespacesAndNewlines))
            let bech32 = try keys.secretKey().toBech32()
            try SharedKeychain.saveNsec(bech32)
            signerPubkey = keys.publicKey().toHex()
            SharedConstants.sharedDefaults.set(signerPubkey, forKey: SharedConstants.signerPubkeyHexKey)
            isKeyImported = true
            statusMessage = "Key imported"
            nsecInput = ""
        } catch {
            statusMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private func generateKey() {
        do {
            let keys = Keys.generate()
            let bech32 = try keys.secretKey().toBech32()
            try SharedKeychain.saveNsec(bech32)
            signerPubkey = keys.publicKey().toHex()
            SharedConstants.sharedDefaults.set(signerPubkey, forKey: SharedConstants.signerPubkeyHexKey)
            isKeyImported = true
            statusMessage = "New key generated"
        } catch {
            statusMessage = "Generate failed: \(error.localizedDescription)"
        }
    }

    private func deleteKey() {
        SharedKeychain.deleteNsec()
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.signerPubkeyHexKey)
        signerPubkey = ""
        isKeyImported = false
        statusMessage = "Key deleted"
    }

    private func registerWithProxy() {
        guard !deviceToken.isEmpty else {
            statusMessage = "No device token available"
            return
        }

        let urlString = "\(proxyURL)/register"
        guard let url = URL(string: urlString) else {
            statusMessage = "Invalid proxy URL"
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["token": deviceToken]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        statusMessage = "Registering..."
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    statusMessage = "Registration failed: \(error.localizedDescription)"
                    return
                }
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    statusMessage = "Registered with proxy"
                } else {
                    statusMessage = "Registration failed"
                }
            }
        }.resume()
    }
}
