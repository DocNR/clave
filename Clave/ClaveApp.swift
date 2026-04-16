import SwiftUI
import UIKit
import NostrSDK
import os.log

private let logger = Logger(subsystem: "dev.nostr.clave", category: "app")

@main
struct ClaveApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            logger.notice("[APNs] Authorization granted: \(granted), error: \(String(describing: error))")
            if granted {
                DispatchQueue.main.async {
                    application.registerForRemoteNotifications()
                }
            }
        }
        SharedStorage.migrateIfNeeded()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        logger.notice("[APNs] Device token: \(token, privacy: .public)")
        SharedConstants.sharedDefaults.set(token, forKey: SharedConstants.deviceTokenKey)
        // Registration with the proxy is handled by AppState.importKey/generateKey
        // (on first-time setup) and by the Settings → Register button (on demand).
        // The AppDelegate doesn't have access to the signer nsec without duplicating
        // LightEvent.signNip98 logic, so we no longer register from here.
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        logger.error("[APNs] Failed to register: \(error.localizedDescription)")
    }

    // MARK: - Foreground Push Handling

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        logger.notice("[App] Foreground push received — processing signing request")
        let userInfo = notification.request.content.userInfo

        Task {
            await handleForegroundSigningRequest(userInfo: userInfo)
        }

        completionHandler([])  // suppress display
    }

    private func handleForegroundSigningRequest(userInfo: [AnyHashable: Any]) async {
        guard let nsec = SharedKeychain.loadNsec() else {
            logger.error("[App] No nsec in Keychain")
            return
        }

        let privateKey: Data
        do {
            privateKey = try Bech32.decodeNsec(nsec)
        } catch {
            logger.error("[App] Failed to decode nsec")
            return
        }

        let signerPubkey: String
        do {
            signerPubkey = try LightEvent.pubkeyHex(from: privateKey)
        } catch {
            logger.error("[App] Failed to derive pubkey")
            return
        }

        let relayUrlString = (userInfo["relay_url"] as? String) ?? SharedConstants.relayURL

        do {
            let relay = LightRelay(url: relayUrlString)
            try await relay.connect()

            let now = Int(Date().timeIntervalSince1970)
            // NIP-46 spec: clients MUST include ["p", <signer-pubkey>] on kind:24133
            let filter: [String: Any] = [
                "kinds": [24133],
                "#p": [signerPubkey],
                "since": now - 60,
                "limit": 5
            ]

            var events = try await relay.fetchEvents(filter: filter, timeout: 10.0)

            if events.isEmpty {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let retryFilter: [String: Any] = [
                    "kinds": [24133],
                    "#p": [signerPubkey],
                    "since": now - 120,
                    "limit": 5
                ]
                events = try await relay.fetchEvents(filter: retryFilter, timeout: 10.0)
            }

            relay.disconnect()

            let processedKey = "processedEventIDs"
            var processedIDs = Set(SharedConstants.sharedDefaults.stringArray(forKey: processedKey) ?? [])

            var handledCount = 0
            for event in events {
                guard let eventPubkey = event["pubkey"] as? String,
                      eventPubkey != signerPubkey,
                      let eventId = event["id"] as? String,
                      !processedIDs.contains(eventId) else { continue }

                do {
                    let result = try await LightSigner.handleRequest(
                        privateKey: privateKey,
                        requestEvent: event
                    )
                    processedIDs.insert(eventId)
                    if result.status == "error" && result.errorMessage == "Decrypt failed" {
                        continue
                    }
                    handledCount += 1
                } catch {
                    processedIDs.insert(eventId)
                    logger.notice("[App] Skipping event: \(error.localizedDescription)")
                }
            }

            let trimmed = Array(processedIDs.suffix(50))
            SharedConstants.sharedDefaults.set(trimmed, forKey: processedKey)

            logger.notice("[App] Foreground handled \(handledCount) requests")

            // Notify views to refresh
            if handledCount > 0 {
                await MainActor.run {
                    NotificationCenter.default.post(name: .signingCompleted, object: nil)
                }
            }

        } catch {
            logger.error("[App] Foreground signing error: \(error.localizedDescription)")
        }
    }
}

extension Notification.Name {
    static let signingCompleted = Notification.Name("signingCompleted")
}
