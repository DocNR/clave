import SwiftUI

struct MainTabView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase

    /// Pending stop deferred during the .inactive grace window. Cancelled if
    /// .active resumes within 2s (e.g. control-center swipe, app-switcher peek).
    @State private var pendingStopTask: Task<Void, Never>? = nil

    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }

            ActivityView()
                .tabItem {
                    Label("Activity", systemImage: "list.bullet")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhase(phase)
        }
        // Root pending-approval alert. Lives at MainTabView level so it
        // presents over any tab (Home, Activity, Settings) and any pushed
        // child route (AccountDetailView, ClientDetailView). Pre-this
        // change the only approval UI was the orange card on Home — out
        // of sight on every other tab. The alert auto-chains: SwiftUI
        // re-evaluates the binding whenever pendingRequests mutates, so
        // after Approve/Deny the next request in queue presents
        // immediately, with "(N of M)" reflecting remaining count.
        //
        // The presenting: overload (race-safe pattern from SettingsView's
        // delete-account alert, build 48 fix `1729ada`) captures the
        // current request value at present-time so the action closures
        // operate on a stable snapshot even if the underlying queue
        // mutates mid-flight (e.g. lock-screen Approve fires on the same
        // request while the alert is still on screen).
        .alert(
            alertTitle,
            isPresented: Binding(
                get: { appState.activeApprovalRequest != nil },
                set: { _ in
                    // No-op setter is critical for auto-chain. SwiftUI
                    // calls setter(false) synchronously when ANY button is
                    // tapped (including Approve/Deny — they're not the
                    // .cancel role but SwiftUI dismisses the alert on tap
                    // regardless). At that moment the async approve/deny
                    // Task hasn't run yet, so pendingRequests still has the
                    // current request, and any "if request still active,
                    // treat as dismissal" logic here would incorrectly add
                    // the in-flight id to dismissedAlertRequestIds — which
                    // breaks the chain because the next request would then
                    // re-arm but SwiftUI is already in dismissal animation.
                    //
                    // Auto-chain works because the binding's getter re-
                    // evaluates as `pendingRequests` mutates (Task completes
                    // → request removed → next freshPendingRequests.first
                    // becomes activeApprovalRequest); the alert's
                    // `presenting:` value rotates to the next request and
                    // SwiftUI updates content in place. No dismissal,
                    // no re-presentation.
                    //
                    // Explicit dismissal happens via the "Not now" button
                    // calling `dismissActiveAlert()` directly. System-
                    // driven dismissals (backgrounding) don't fire setter
                    // because iOS alerts persist across foreground state.
                }
            ),
            presenting: appState.activeApprovalRequest
        ) { request in
            Button("Not now", role: .cancel) {
                // Explicit "I'll handle the whole batch via the bell" —
                // dismisses all currently-fresh pending alerts, not just
                // the active one. Per-request dismissal would auto-chain
                // to the next request's alert immediately, which is the
                // very "alert keeps popping back up" UX this button is
                // supposed to escape. Bell badge / inbox sheet still
                // surface every dismissed request.
                appState.dismissAllActiveAlerts()
            }
            Button("Deny", role: .destructive) {
                appState.denyPendingRequest(request)
            }
            Button("Approve") {
                Task { _ = await appState.approvePendingRequest(request) }
            }
        } message: { request in
            Text(alertMessage(for: request))
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            // Cancel any pending stop and start the foreground subscription.
            pendingStopTask?.cancel()
            pendingStopTask = nil
            Task { @MainActor in
                appState.startForegroundSubscription()
            }
            // Pull cross-process pending-requests writes (NSE while we were
            // backgrounded). The in-process .pendingRequestsUpdated observer
            // in AppState handles the L1 path; this catches NSE-side queues.
            //
            // Purge stale (>5 min) entries on every foregrounding so the
            // root alert never fires for requests the client has already
            // given up on, and writes "expired" ActivityEntry rows for
            // visibility in the activity log. Order matters: purge first,
            // then refresh — otherwise the @Observable pendingRequests
            // surface would briefly contain stale rows on first wake.
            appState.purgeStalePendingRequests()
            appState.refreshPendingRequests()
            // Opportunistic re-register if any account's cached "last success"
            // is stale or the last attempt failed (e.g. POST timed out on bad
            // cellular). Per-account throttle prevents hammering. Cheap
            // idempotent upsert on the proxy side. Multi-account: iterates
            // all accounts so a non-current account that's overdue still
            // gets refreshed.
            appState.ensureAllRegisteredFresh()
            // Sweep blank NC entries (see NotificationCenterSweep.swift).
            sweepBlankNotifications()
        case .inactive:
            // 2s grace window for app-switcher peeks / control-center swipes.
            pendingStopTask?.cancel()
            pendingStopTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                appState.stopForegroundSubscription()
            }
            // Also sweep on tap-away — catches the case where a tester opens
            // NC via swipe-down WHILE Clave is the most-recent foreground app
            // but isn't currently `.active`. Small additional cost (one async
            // get + filter); harmless in the common case where there are no
            // blank entries.
            sweepBlankNotifications()
        case .background:
            // Confirmed background — stop immediately.
            pendingStopTask?.cancel()
            pendingStopTask = nil
            Task { @MainActor in
                appState.stopForegroundSubscription()
            }
        @unknown default:
            break
        }
    }

    // MARK: - Alert content

    /// Title is method-aware (sign vs encrypt vs decrypt) and shows the
    /// queue position when 2+ requests are pending so users know how
    /// deep the chain runs before they start tapping.
    private var alertTitle: String {
        guard let request = appState.activeApprovalRequest else { return "" }
        let base: String
        switch request.method {
        case "sign_event":
            base = "Approve Signing Request"
        case "nip04_encrypt", "nip44_encrypt":
            base = "Approve Encryption Request"
        case "nip04_decrypt", "nip44_decrypt":
            base = "Approve Decryption Request"
        default:
            base = "Approve Request"
        }
        let depth = appState.pendingApprovalQueueDepth
        return depth > 1 ? "\(base) (1 of \(depth))" : base
    }

    private func alertMessage(for request: PendingRequest) -> String {
        var lines: [String] = []
        let clientLabel = SharedStorage.getClientPermissions(for: request.clientPubkey)?.name
            ?? "Client …\(request.clientPubkey.suffix(8))"
        lines.append("From: \(clientLabel)")

        if request.method == "sign_event", let kind = request.eventKind {
            lines.append(KnownKinds.label(for: kind))
        } else {
            lines.append("Method: \(request.method)")
        }

        if appState.accounts.count > 1 {
            let pubkey = request.signerPubkeyHex.isEmpty
                ? appState.signerPubkeyHex
                : request.signerPubkeyHex
            let label = appState.accounts.first(where: { $0.pubkeyHex == pubkey })?.displayLabel
                ?? String(pubkey.prefix(8))
            lines.append("Signing as: @\(label)")
        }

        return lines.joined(separator: "\n")
    }
}
