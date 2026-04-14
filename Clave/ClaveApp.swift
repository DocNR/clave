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
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        logger.notice("[APNs] Device token: \(token, privacy: .public)")
        SharedConstants.sharedDefaults.set(token, forKey: SharedConstants.deviceTokenKey)

        // Only register with the proxy if the user has set up a key. Registering
        // before a key exists means the device gets pushes for other users' events
        // and the NSE fires with no key → was causing "Signing Failed" spam for
        // fresh installs that never completed onboarding.
        if SharedKeychain.loadNsec() != nil {
            autoRegisterWithProxy(token: token)
        } else {
            logger.notice("[APNs] Skipping proxy registration — no signer key yet")
        }
    }

    private func autoRegisterWithProxy(token: String, attempt: Int = 1) {
        let proxyURL = SharedConstants.sharedDefaults.string(forKey: SharedConstants.proxyURLKey)
            ?? SharedConstants.defaultProxyURL
        let hasSecret = SharedConstants.sharedDefaults.string(forKey: SharedConstants.proxyRegisterSecretKey)?.isEmpty == false

        logger.notice("[APNs] Auto-register attempt \(attempt): url=\(proxyURL, privacy: .public) hasSecret=\(hasSecret)")

        guard let url = URL(string: "\(proxyURL)/register") else {
            logger.error("[APNs] Invalid proxy URL: \(proxyURL, privacy: .public)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let secret = SharedConstants.sharedDefaults.string(forKey: SharedConstants.proxyRegisterSecretKey)
            ?? SharedConstants.defaultProxyRegisterSecret
        if !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            if let httpResponse = response as? HTTPURLResponse {
                logger.notice("[APNs] Proxy response: \(httpResponse.statusCode)")
                if httpResponse.statusCode == 200 {
                    logger.notice("[APNs] Auto-registered with proxy")
                    return
                }
            }
            if let error {
                logger.error("[APNs] Proxy error: \(error.localizedDescription, privacy: .public)")
            }
            if attempt < 3 {
                logger.notice("[APNs] Retrying in \(attempt * 2)s...")
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt * 2)) {
                    self?.autoRegisterWithProxy(token: token, attempt: attempt + 1)
                }
            } else {
                logger.error("[APNs] Proxy registration failed after 3 attempts")
            }
        }.resume()
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
