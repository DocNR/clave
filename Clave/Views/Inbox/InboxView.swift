import SwiftUI

/// Sheet-presented inbox of pending NIP-46 sign / encrypt / decrypt
/// requests. The bell `ToolbarItem` on `HomeView` opens this sheet;
/// users can swipe-approve / swipe-deny rows inline, or tap a row to
/// drill into `PendingRequestDetailView` for full context and the
/// "Always allow this kind" toggle.
///
/// All UI here reads from `appState.freshPendingRequests` — the
/// TTL-filtered surface (5 min). Stale requests don't appear; they're
/// purged in the background by `AppState.purgeStalePendingRequests`.
struct InboxView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if appState.freshPendingRequests.isEmpty {
                    ContentUnavailableView(
                        "No pending requests",
                        systemImage: "tray",
                        description: Text("Sign requests from connected clients will appear here.")
                    )
                } else {
                    List {
                        ForEach(appState.freshPendingRequests) { request in
                            NavigationLink(value: request) {
                                PendingRequestRow(request: request)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    Task { _ = await appState.approvePendingRequest(request) }
                                } label: {
                                    Label("Approve", systemImage: "checkmark.circle.fill")
                                }
                                .tint(.green)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    appState.denyPendingRequest(request)
                                } label: {
                                    Label("Deny", systemImage: "xmark.circle.fill")
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Pending Requests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: PendingRequest.self) { request in
                PendingRequestDetailView(request: request)
            }
        }
    }
}
