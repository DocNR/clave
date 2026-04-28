import SwiftUI
import UserNotifications

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
            // Sweep blank Notification Center entries from NSE silent-success
            // wakes. NSE calls removeDeliveredNotifications immediately after
            // contentHandler, but the NSE process often exits before iOS has
            // committed the notification, so the remove no-ops. The L1 dedupe
            // makes this much more frequent (every NSE wake for an event L1
            // already processed returns .noEvents → blank entry). Cleaning
            // here works because the main app process lives long enough for
            // the async API to actually complete.
            sweepBlankNotifications()
        case .inactive:
            // 2s grace window for app-switcher peeks / control-center swipes.
            pendingStopTask?.cancel()
            pendingStopTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                appState.stopForegroundSubscription()
            }
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

    /// Removes any delivered notification with an empty title — these are NSE
    /// silent-success / .noEvents wakes that should never have appeared in
    /// Notification Center but did, due to the NSE-exit-before-iOS-commit
    /// race. Locally-scheduled pending-approval banners ("Approve Signing
    /// Request"), sign-failure banners ("Signing Failed"), and any other
    /// real notification keep their title and are preserved.
    private func sweepBlankNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let blankIds = delivered
                .filter { $0.request.content.title.isEmpty }
                .map { $0.request.identifier }
            guard !blankIds.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: blankIds)
        }
    }
}
