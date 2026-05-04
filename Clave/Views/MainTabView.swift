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
}
