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
}
