import SwiftUI

struct ContentView: View {
    @State private var appState = AppState()

    var body: some View {
        Group {
            if appState.isKeyImported {
                MainTabView()
            } else {
                OnboardingView()
            }
        }
        .environment(appState)
        .onAppear { appState.loadState() }
    }
}
