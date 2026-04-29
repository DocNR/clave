import SwiftUI
import UserNotifications
import UIKit

/// Developer diagnostics for the L1 foreground relay subscription.
/// Reachable from Settings → Developer (after the 7-tap unlock).
///
/// Surfaces the live state of `ForegroundRelaySubscription.shared` plus the
/// system notification permission. Designed so a tester can answer "is L1
/// running and why isn't a banner appearing?" without parsing log output.
struct L1DiagnosticsView: View {
    @State private var l1 = ForegroundRelaySubscription.shared
    @State private var now = Date()
    @State private var notificationSettings: UNNotificationSettings?

    private let tickTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    private let notifTimer = Timer.publish(every: 5.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            statusSection
            countersSection
            latencySection
            if let err = l1.lastError {
                Section("Last error") {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            relaysSection
            notificationsSection
            actionsSection
        }
        .navigationTitle("L1 Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshNotificationSettings() }
        .onReceive(tickTimer) { now = $0 }
        .onReceive(notifTimer) { _ in refreshNotificationSettings() }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section("Status") {
            HStack {
                Circle()
                    .fill(stateColor(l1.state))
                    .frame(width: 10, height: 10)
                Text(l1.state.rawValue)
                    .font(.footnote.bold())
            }
            labeled("Status message", value: l1.statusMessage)
            labeled("Session age", value: sessionAgeString())
        }
    }

    private var countersSection: some View {
        Section("Counters") {
            labeled("Events received", value: "\(l1.eventsReceived)")
            labeled("Events processed", value: "\(l1.eventsProcessed)")
            labeled("Events failed", value: "\(l1.eventsFailed)")
        }
    }

    private var latencySection: some View {
        Section("Latency") {
            let samples = l1.recentLatenciesMs
            labeled("Samples", value: "\(samples.count)")
            labeled("p50", value: percentileString(samples, p: 0.5))
            labeled("p95", value: percentileString(samples, p: 0.95))
        }
    }

    private var relaysSection: some View {
        Section("Relays (\(l1.currentRelays.count))") {
            if l1.currentRelays.isEmpty {
                Text("—")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(l1.currentRelays, id: \.self) { url in
                    Text(url)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private var notificationsSection: some View {
        Section("Notifications") {
            if let s = notificationSettings {
                let authText = authorizationLabel(s.authorizationStatus)
                let isAuthorized = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
                HStack {
                    Text("Authorization")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(authText)
                        .font(.footnote.bold())
                        .foregroundStyle(isAuthorized ? .primary : .red)
                }
                labeled("Alert", value: settingLabel(s.alertSetting))
                labeled("Sound", value: settingLabel(s.soundSetting))
                labeled("Badge", value: settingLabel(s.badgeSetting))
                if !isAuthorized {
                    Text("Banners cannot appear until iOS notifications are authorized.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } else {
                Text("Reading…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionsSection: some View {
        Section("Actions") {
            Button {
                l1.stop()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    l1.start()
                }
            } label: {
                Label("Restart L1", systemImage: "arrow.clockwise")
            }

            Button {
                l1.resetCounters()
            } label: {
                Label("Reset counters", systemImage: "0.circle")
            }

            Button {
                openNotificationSettings()
            } label: {
                Label("Open iOS Notification Settings", systemImage: "bell.badge")
            }
        }
    }

    // MARK: - Helpers

    private func stateColor(_ state: ForegroundRelaySubscription.State) -> Color {
        switch state {
        case .listening: return .green
        case .starting, .reconnecting: return .orange
        case .error: return .red
        case .idle, .stopping: return .gray
        }
    }

    private func sessionAgeString() -> String {
        guard let start = l1.sessionStartedAt else { return "—" }
        let elapsed = Int(now.timeIntervalSince(start))
        if elapsed < 60 { return "\(elapsed)s" }
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        if minutes < 60 { return String(format: "%dm %02ds", minutes, seconds) }
        let hours = minutes / 60
        let remMinutes = minutes % 60
        return String(format: "%dh %02dm", hours, remMinutes)
    }

    private func percentileString(_ samples: [Double], p: Double) -> String {
        guard !samples.isEmpty else { return "—" }
        let sorted = samples.sorted()
        let idx = min(sorted.count - 1, max(0, Int(Double(sorted.count) * p)))
        return String(format: "%.0f ms", sorted[idx])
    }

    private func authorizationLabel(_ s: UNAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "not determined"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    private func settingLabel(_ s: UNNotificationSetting) -> String {
        switch s {
        case .enabled: return "enabled"
        case .disabled: return "disabled"
        case .notSupported: return "not supported"
        @unknown default: return "unknown"
        }
    }

    private func refreshNotificationSettings() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { self.notificationSettings = settings }
        }
    }

    private func openNotificationSettings() {
        if #available(iOS 16.0, *),
           let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            UIApplication.shared.open(url)
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    @ViewBuilder
    private func labeled(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.footnote)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
