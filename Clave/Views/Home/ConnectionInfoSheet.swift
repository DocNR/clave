import SwiftUI
import NostrSDK

/// Detailed view of a paired client connection: name, pubkey (hex + npub),
/// origin URL, connect/last-seen timestamps, total requests handled, and
/// the relay set the proxy watches on this client's behalf. Reachable from
/// the ClientDetailView toolbar overflow menu.
struct ConnectionInfoSheet: View {
    let perms: ClientPermissions
    @Environment(\.dismiss) private var dismiss

    private var connectedClient: ConnectedClient? {
        // Task 7: scope to (signer, client). `perms` carries
        // signerPubkeyHex (Task 3); use it so the same client paired
        // with multiple accounts produces the correct row per account.
        SharedStorage.getConnectedClients(for: perms.signerPubkeyHex).first { $0.pubkey == perms.pubkey }
    }

    private var npub: String {
        guard let pk = try? PublicKey.parse(publicKey: perms.pubkey) else { return "" }
        return (try? pk.toBech32()) ?? ""
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    if let name = perms.name {
                        labeled("Name", value: name)
                    }
                    if let url = perms.url {
                        labeled("Origin", value: url, monospaced: false)
                    }
                    if !npub.isEmpty {
                        labeled("npub", value: npub, monospaced: true, copyable: true)
                    }
                    labeled("Pubkey (hex)", value: perms.pubkey, monospaced: true, copyable: true)
                }

                Section("Activity") {
                    labeled("Trust level", value: trustLabel(perms.trustLevel))
                    labeled("First connected", value: absoluteDate(perms.connectedAt))
                    labeled("Last seen", value: absoluteDate(perms.lastSeen))
                    if let cc = connectedClient {
                        labeled("Total requests", value: "\(cc.requestCount)")
                    }
                }

                if let cc = connectedClient, !cc.relayUrls.isEmpty {
                    Section("Paired relays") {
                        ForEach(cc.relayUrls, id: \.self) { url in
                            Text(url)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("Connection Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func labeled(_ label: String, value: String, monospaced: Bool = false, copyable: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                Text(value)
                    .font(monospaced ? .system(.footnote, design: .monospaced) : .footnote)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if copyable {
                    Button {
                        UIPasteboard.general.string = value
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func trustLabel(_ level: TrustLevel) -> String {
        switch level {
        case .full: return "Full"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    private func absoluteDate(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
