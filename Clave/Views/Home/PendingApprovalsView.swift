import SwiftUI

struct PendingApprovalsView: View {
    @Environment(AppState.self) private var appState
    @State private var processing: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                Text("Pending Approvals")
                    .font(.headline)
                Spacer()
                Text("\(appState.pendingRequests.count)")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.orange.opacity(0.15), in: Capsule())
            }

            ForEach(appState.pendingRequests) { request in
                requestRow(request)
            }
        }
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.orange.opacity(0.08))
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
        }
        // The wrapping Section in HomeView strips list-row insets so other
        // cards (identityBar, statsRow) can self-pad. This mirrors that
        // pattern so the orange border doesn't touch screen edges.
        .padding(.horizontal)
    }

    private func requestRow(_ request: PendingRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(request.method)
                            .font(.subheadline.bold())
                        if let kind = request.eventKind {
                            Text(kindLabel(kind))
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(.systemGray5), in: Capsule())
                        }
                    }

                    Text(truncatedPubkey(request.clientPubkey))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(relativeTime(request.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            let isProcessing = processing.contains(request.id)
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button { approve(request) } label: {
                        Label("Approve", systemImage: "checkmark")
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(isProcessing)

                    Button { appState.denyPendingRequest(request) } label: {
                        Label("Deny", systemImage: "xmark")
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isProcessing)
                }

                if request.eventKind != nil {
                    Button { alwaysAllow(request) } label: {
                        Label("Always Allow This Kind", systemImage: "checkmark.shield")
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                    .disabled(isProcessing)
                }
            }

            if isProcessing {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Signing...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func alwaysAllow(_ request: PendingRequest) {
        if let kind = request.eventKind,
           var perms = SharedStorage.getClientPermissions(for: request.clientPubkey) {
            perms.kindOverrides[kind] = true
            SharedStorage.saveClientPermissions(perms)
        }
        approve(request)
    }

    private func approve(_ request: PendingRequest) {
        processing.insert(request.id)
        Task {
            let success = await appState.approvePendingRequest(request)
            processing.remove(request.id)
            if success {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func kindLabel(_ kind: Int) -> String {
        KnownKinds.label(for: kind)
    }

    private func truncatedPubkey(_ hex: String) -> String {
        guard hex.count > 12 else { return hex }
        return String(hex.prefix(8)) + "..." + String(hex.suffix(4))
    }

    private func relativeTime(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
