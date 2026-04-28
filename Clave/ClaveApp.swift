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
        logger.notice("[APNs] Device token: \(token, privacy: .private)")
        SharedConstants.sharedDefaults.set(token, forKey: SharedConstants.deviceTokenKey)
        // AppDelegate doesn't have direct access to the signer nsec (would have
        // to duplicate LightEvent.signNip98 logic), so we signal AppState via
        // NotificationCenter and let it do the actual NIP-98-signed POST.
        // Catches: iOS-rotated tokens, proxy-side token loss, fresh installs
        // where the user already had a key from a prior install. Idempotent on
        // the proxy side (upsert).
        NotificationCenter.default.post(name: .apnsDeviceTokenAvailable, object: token)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        logger.error("[APNs] Failed to register: \(error.localizedDescription)")
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Drain the pair/unpair retry queue. AppState listens for this and
        // processes pendingPairOps.
        NotificationCenter.default.post(name: .drainPendingPairOps, object: nil)
    }

    // MARK: - Foreground Push Handling

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        let title = notification.request.content.title

        // Two flavors of notification reach this delegate while the app is
        // foreground:
        //
        //   1. Locally-scheduled UNNotificationRequest from
        //      PendingApprovalBanner (identifier prefix "pending-approval-").
        //      These have a meaningful title set by us and userInfo is empty.
        //      Show them — that's the whole point of scheduling them.
        //
        //   2. APNs-delivered pushes for sign requests (userInfo contains the
        //      proxy's `aps`/`event_id`/`relay_url` keys). NSE has already
        //      modified their content: empty title for silent success,
        //      "Approve Signing Request" for pending, "Signing Failed" for
        //      error. We process the request again locally for L1-style
        //      handling, AND let iOS display the NSE-modified content if it
        //      has a real title (pending/error). Suppress for empty title
        //      (the silent-success case).
        let identifier = notification.request.identifier
        let isLocalPendingBanner = identifier.hasPrefix("pending-approval-")

        if isLocalPendingBanner {
            // Don't re-process — this is our own scheduled banner, no APNs payload to handle.
            completionHandler([.banner, .sound, .list])
            return
        }

        logger.notice("[App] Foreground push received — processing signing request")
        Task {
            await handleForegroundSigningRequest(userInfo: userInfo)
        }

        if !title.isEmpty {
            // NSE marked this as pending or error — surface it.
            completionHandler([.banner, .sound, .list])
        } else {
            // NSE marked this as silent success — suppress.
            completionHandler([])
        }
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
            var events: [[String: Any]] = []

            // Prefer embedded event from the push payload. See NotificationService.swift
            // for rationale — same fix, same race, same fallback.
            if let embedded = userInfo["event"] as? [String: Any] {
                logger.notice("[App] Using embedded event from push payload")
                events = [embedded]
            } else {
                if userInfo["event"] != nil {
                    logger.warning("[App] event key present but not castable to [String: Any] — falling back to relay fetch")
                } else {
                    logger.notice("[App] No embedded event; fetching from \(relayUrlString, privacy: .public)")
                }
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

                events = try await relay.fetchEvents(filter: filter, timeout: 10.0)

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
            }

            // Per-event dedupe is now done inside LightSigner.handleRequest
            // (audit D.1.1, see SharedStorage.markEventProcessed). Duplicates
            // arriving via both APNs and the foreground subscription return
            // status "skipped-duplicate" without doing decrypt work.

            var handledCount = 0
            // Process connects first so pairing state exists before other methods.
            // Mirrors NotificationService.swift; fixes the same intra-batch race.
            let sortedEvents = events.sorted { a, b in
                let aIsConnect = LightSigner.peekMethod(privateKey: privateKey, event: a) == "connect"
                let bIsConnect = LightSigner.peekMethod(privateKey: privateKey, event: b) == "connect"
                if aIsConnect != bIsConnect { return aIsConnect }
                return (a["created_at"] as? Int ?? 0) < (b["created_at"] as? Int ?? 0)
            }

            for event in sortedEvents {
                guard let eventPubkey = event["pubkey"] as? String,
                      eventPubkey != signerPubkey else { continue }

                do {
                    let result = try await LightSigner.handleRequest(
                        privateKey: privateKey,
                        requestEvent: event,
                        responseRelayUrl: relayUrlString
                    )
                    if result.status == "error" && result.errorMessage == "Decrypt failed" {
                        continue
                    }
                    if result.status == "skipped-duplicate" {
                        continue
                    }
                    handledCount += 1
                    // Same reason as ForegroundRelaySubscription: when this
                    // foreground push handler queues a pending approval, NSE
                    // for the same event will dedupe and produce no banner.
                    // Schedule one here so the user gets the alert.
                    if result.status == "pending", let requestId = result.pendingRequestId {
                        await MainActor.run {
                            PendingApprovalBanner.schedule(
                                requestId: requestId,
                                clientPubkey: result.clientPubkey,
                                eventKind: result.eventKind
                            )
                        }
                    }
                } catch {
                    logger.notice("[App] Skipping event: \(error.localizedDescription)")
                }
            }

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
    static let drainPendingPairOps = Notification.Name("drainPendingPairOps")
    /// Posted by AppDelegate.didRegisterForRemoteNotificationsWithDeviceToken
    /// every time iOS hands us a device token (every launch + on rotations).
    /// AppState observes and re-registers with the proxy if a signer key
    /// exists. Object is the hex-encoded token string.
    static let apnsDeviceTokenAvailable = Notification.Name("apnsDeviceTokenAvailable")
}
