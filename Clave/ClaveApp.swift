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
                .onOpenURL { url in
                    handleDeeplink(url: url)
                }
        }
    }

    @MainActor
    private func handleDeeplink(url: URL) {
        logger.notice("[Deeplink] received: \(url.absoluteString, privacy: .public)")
        NotificationCenter.default.post(name: .deeplinkReceived, object: url)
    }
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        registerPendingApprovalCategory()
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

    /// Wires up the long-press / swipe-down action buttons on the
    /// pending-approval notification (NSE-modified APNs push, or local
    /// L1 banner). Both notification emission paths set
    /// `categoryIdentifier = PendingApprovalCategory.identifier`; this
    /// registers the matching category so the system knows which actions
    /// to render. Both actions run in the background — Clave does NOT
    /// come to foreground when you tap Approve/Deny; the action handler
    /// loads the nsec, signs (or removes the row for deny), publishes
    /// the response, and clears the banner without a foreground
    /// transition. Approve still requires biometric auth via
    /// `.authenticationRequired` before iOS dispatches the action —
    /// shoulder-surfing defense.
    ///
    /// User-facing reminder: action buttons aren't rendered inline on
    /// the compact banner — iOS hides them until the user long-presses
    /// (or pulls down on) the banner. This is platform-standard, not a
    /// Clave-specific decision. The post-set verification log below
    /// helps debug "I don't see actions on the banner" reports — if
    /// the category isn't listed in Console, a registration timing or
    /// build issue is at play; otherwise the user just needs to use
    /// the long-press gesture.
    private func registerPendingApprovalCategory() {
        let approveAction = UNNotificationAction(
            identifier: PendingApprovalCategory.approveActionId,
            title: "Approve",
            // No `.foreground` — Approve must NOT open the app. The
            // handler in `userNotificationCenter(_:didReceive:)` runs
            // in the main app process either way (iOS launches us in
            // background if terminated); we just don't want the
            // foreground UI transition. `.authenticationRequired` still
            // gates with Face ID before the handler fires.
            options: [.authenticationRequired]
        )
        let denyAction = UNNotificationAction(
            identifier: PendingApprovalCategory.denyActionId,
            title: "Deny",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: PendingApprovalCategory.identifier,
            actions: [approveAction, denyAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
        UNUserNotificationCenter.current().getNotificationCategories { categories in
            let ids = categories.map { $0.identifier }.sorted()
            logger.notice("[App] notification categories registered: \(ids, privacy: .public)")
        }
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
            logger.notice("[App] willPresent: local banner id=\(identifier, privacy: .public) — show")
            completionHandler([.banner, .sound, .list])
            return
        }

        logger.notice("[App] Foreground push received — processing signing request")
        Task {
            await handleForegroundSigningRequest(userInfo: userInfo)
        }

        if !title.isEmpty {
            // NSE marked this as pending or error — surface it.
            logger.notice("[App] willPresent: APNs push title=\"\(title, privacy: .public)\" — show")
            completionHandler([.banner, .sound, .list])
        } else {
            // NSE marked this as silent success — suppress.
            logger.notice("[App] willPresent: APNs push empty title — suppress")
            completionHandler([])
        }
    }

    // MARK: - Lock-Screen Action Routing
    //
    // Fires when the user taps Approve or Deny on the long-press / swipe
    // pending-approval notification UI. We do NOT route through AppState
    // because AppDelegate doesn't own it (held by ContentView's @State)
    // and during a cold launch from a notification action the SwiftUI
    // view tree hasn't initialized yet — a NotificationCenter-based
    // dispatch would post into the void. Instead we call the static
    // `AppState.handlePendingApprovalAction` path, which does the
    // SharedStorage + LightSigner work directly. The AppState instance
    // (if alive) observes the resulting `.pendingRequestsUpdated` post
    // from SharedStorage and refreshes its UI surface.
    //
    // Approve runs in background (no `.foreground` flag on the action) —
    // user stays where they were, sees the banner clear when signing
    // completes. iOS gives the app ~30s of background time which is
    // ample for a typical sign+publish round-trip. Face ID is gated by
    // the action's `.authenticationRequired` option before this handler
    // is even called.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let actionId = response.actionIdentifier
        logger.notice("[App] didReceive action=\(actionId, privacy: .public)")

        // Default action (notification body tap) and dismiss action: nothing
        // to route — iOS brings the app forward (or doesn't), and the root
        // alert presents over whatever loads if there's still a pending
        // request in queue.
        guard actionId == PendingApprovalCategory.approveActionId
              || actionId == PendingApprovalCategory.denyActionId else {
            completionHandler()
            return
        }

        guard let requestId = userInfo["pendingRequestId"] as? String else {
            logger.error("[App] action \(actionId, privacy: .public) without pendingRequestId in userInfo")
            completionHandler()
            return
        }

        // Hold the system completion handler until the work finishes so
        // iOS knows we're still doing useful work and gives us the full
        // background time budget. For Deny this is microseconds; for
        // Approve it's typically <2s (relay round-trip).
        Task {
            await AppState.handlePendingApprovalAction(
                requestId: requestId,
                actionId: actionId
            )
            completionHandler()
        }
    }

    private func handleForegroundSigningRequest(userInfo: [AnyHashable: Any]) async {
        // Task 6: pubkey-route the Keychain lookup. Same payload-first /
        // currentSignerPubkeyHexKey fallback as NSE.
        let signerPubkey = SharedKeychain.resolveSignerPubkey(userInfo: userInfo)
        guard !signerPubkey.isEmpty,
              let nsec = SharedKeychain.loadNsec(for: signerPubkey) else {
            logger.error("[App] No nsec for resolved signer (\(signerPubkey.prefix(8), privacy: .public))")
            return
        }

        let privateKey: Data
        do {
            privateKey = try Bech32.decodeNsec(nsec)
        } catch {
            logger.error("[App] Failed to decode nsec")
            return
        }

        // Defense-in-depth: verify Keychain entry's nsec derives back to
        // the pubkey we routed by.
        let derivedPubkey: String
        do {
            derivedPubkey = try LightEvent.pubkeyHex(from: privateKey)
        } catch {
            logger.error("[App] Failed to derive pubkey")
            return
        }
        guard derivedPubkey == signerPubkey else {
            logger.error("[App] Pubkey mismatch: resolved=\(signerPubkey.prefix(8), privacy: .public) derived=\(derivedPubkey.prefix(8), privacy: .public)")
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

            // Notify views to refresh — unconditionally. The previous gate on
            // `handledCount > 0` missed the dedupe-by-NSE case: NSE writes a
            // pending request to cross-process storage, then the foreground
            // push for the same event reaches this handler, every event
            // returns "skipped-duplicate", handledCount stays 0, and no
            // refresh signal fires. The pending row would only appear after
            // the user backgrounds + foregrounds (MainTabView's scenePhase
            // observer). Posting both signals every time covers:
            //   .pendingRequestsUpdated → AppState.refreshPendingRequests
            //     (cross-process pending writes from NSE)
            //   .signingCompleted → HomeView/ActivityView counter refresh
            //     (signedToday, per-client requestCount)
            await MainActor.run {
                NotificationCenter.default.post(name: .pendingRequestsUpdated, object: nil)
                NotificationCenter.default.post(name: .signingCompleted, object: nil)
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
    /// Posted by ClaveApp.onOpenURL when iOS opens the app via a registered
    /// URL scheme (nostrconnect:// or clave://). AppState observes and routes
    /// via DeeplinkRouter to the appropriate pending state.
    static let deeplinkReceived = Notification.Name("deeplinkReceived")
}
