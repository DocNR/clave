import Foundation
import UserNotifications
import os.log

private let logger = Logger(subsystem: "dev.nostr.clave", category: "banner")

/// Schedules a local notification when a sign request is queued for user approval
/// and the request was processed *in the main app process* (L1 foreground sub or
/// foreground APNs push handler). NSE doesn't call this — it modifies the APNs
/// content via `contentHandler` directly (see `ClaveNSE/NotificationService.swift`
/// `deliverContent` `.pending` case). Calling from both would double-notify.
///
/// Why this exists: pre-L1, every sign request reached Clave via APNs → NSE,
/// and NSE's pending banner was the user-visible signal. After L1 (PR #11),
/// when Clave is foregrounded or in the 2s `.inactive` grace window, L1 catches
/// the request first and marks it processed via `SharedStorage.markEventProcessed`.
/// NSE then runs from the same APNs push, sees the dedupe, returns
/// `.noEvents`, and produces a silent passive notification (correct — L1 already
/// handled it). The banner the user expects has to come from the L1 path itself,
/// which this helper provides.
enum PendingApprovalBanner {
    /// Schedules a local notification matching the format NSE uses for
    /// pending-approval pushes (title "Approve Signing Request", body
    /// "<client> wants to sign <kind>", `.active` interruption).
    ///
    /// Idempotent on identifier collisions — UNUserNotificationCenter
    /// replaces an existing pending request with the same identifier.
    /// We pass the request id so denying/approving the same request won't
    /// stack banners.
    static func schedule(requestId: String, clientPubkey: String, eventKind: Int?) {
        let content = makeContent(
            requestId: requestId,
            clientPubkey: clientPubkey,
            eventKind: eventKind
        )

        // No trigger → deliver immediately.
        let request = UNNotificationRequest(
            identifier: "pending-approval-\(requestId)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("[Banner] Failed to schedule pending-approval banner: \(error.localizedDescription, privacy: .public)")
            } else {
                logger.notice("[Banner] Scheduled pending-approval banner client=\(clientPubkey.prefix(8), privacy: .public) kind=\(eventKind ?? -1, privacy: .public)")
            }
        }
    }

    /// Pure builder for the notification content. Extracted from
    /// `schedule` so unit tests can verify the categoryIdentifier +
    /// userInfo wiring without depending on UNUserNotificationCenter
    /// authorization or delivery — which are flaky in the simulator
    /// test runner.
    static func makeContent(
        requestId: String,
        clientPubkey: String,
        eventKind: Int?
    ) -> UNMutableNotificationContent {
        let clientName = SharedStorage.getClientPermissions(for: clientPubkey)?.name
            ?? String(clientPubkey.prefix(8))
        let kindDesc = eventKind.map { KnownKinds.label(for: $0) } ?? "event"

        let content = UNMutableNotificationContent()
        content.title = "Approve Signing Request"
        content.body = "\(clientName) wants to sign \(kindDesc)"
        content.sound = .default
        content.interruptionLevel = .active
        // Wires the long-press / swipe-down notification UI to surface
        // Approve + Deny action buttons. Category is registered in
        // AppDelegate.didFinishLaunchingWithOptions; pendingRequestId is
        // looked up by AppState's action observer to find the matching
        // PendingRequest in SharedStorage.
        content.categoryIdentifier = PendingApprovalCategory.identifier
        content.userInfo = ["pendingRequestId": requestId]
        return content
    }

    /// Removes the delivered/pending banner for a given request id. Called when
    /// the user approves or denies a pending request via the UI so the banner
    /// doesn't linger in Notification Center.
    static func clear(requestId: String) {
        let identifier = "pending-approval-\(requestId)"
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
