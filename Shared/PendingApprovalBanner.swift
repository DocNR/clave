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
    /// the user approves, denies, or the TTL purge expires a pending request,
    /// so the banner doesn't linger in Notification Center.
    ///
    /// Two flavors of banner can exist for a given pending request:
    ///
    ///   1. Locally-scheduled by `schedule(...)` above — identifier
    ///      `"pending-approval-<requestId>"`. The synchronous remove below
    ///      handles these.
    ///   2. NSE-delivered via APNs (`ClaveNSE/NotificationService.swift`
    ///      `.pending` case). These use the APNs request identifier (proxy-
    ///      assigned, not our prefix), so we have to match by `userInfo`
    ///      payload. The async path below enumerates delivered notifications
    ///      and removes any whose `categoryIdentifier` is ours and whose
    ///      `pendingRequestId` userInfo matches.
    ///
    /// Without (2), a TTL-purged or approved/denied request leaves an NSE-
    /// delivered banner stranded in Notification Center; long-pressing
    /// Approve from the stale banner would silently fail because the
    /// `SharedStorage` row is already gone.
    static func clear(requestId: String) {
        let center = UNUserNotificationCenter.current()
        let localIdentifier = "pending-approval-\(requestId)"
        center.removePendingNotificationRequests(withIdentifiers: [localIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [localIdentifier])

        Task {
            let delivered = await center.deliveredNotifications()
            let snapshots = delivered.map(DeliveredNotificationSnapshot.init(from:))
            let nseIdentifiers = nseDeliveredIds(forRequest: requestId, in: snapshots)
            guard !nseIdentifiers.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: nseIdentifiers)
            logger.notice("[Banner] Cleared \(nseIdentifiers.count, privacy: .public) NSE-delivered banner(s) for request \(requestId.prefix(8), privacy: .public)")
        }
    }

    /// Pure filter: returns identifiers of notifications that are NSE-delivered
    /// pending-approval banners for the given request id. Extracted so unit
    /// tests can verify the matcher without touching `UNUserNotificationCenter`.
    static func nseDeliveredIds(
        forRequest requestId: String,
        in delivered: [DeliveredNotificationSnapshot]
    ) -> [String] {
        delivered.compactMap { snapshot in
            guard snapshot.categoryIdentifier == PendingApprovalCategory.identifier else { return nil }
            guard let id = snapshot.userInfo["pendingRequestId"] as? String,
                  id == requestId else { return nil }
            return snapshot.identifier
        }
    }

    /// Pure filter: returns identifiers of notifications whose title and body
    /// are both empty after trimming. Used by the NSE-side sweep that runs at
    /// the start of each wake to clean up blanks left behind by prior wakes
    /// (see `ClaveNSE/NotificationService.swift`). Mirrors the logic in
    /// `Clave/Views/Components/NotificationCenterSweep.swift` but runs in a
    /// context where the racy NSE-self-cleanup pattern can't reach.
    static func blankDeliveredIds(
        in delivered: [DeliveredNotificationSnapshot]
    ) -> [String] {
        delivered.compactMap { snapshot in
            let trimmedTitle = snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedBody = snapshot.body.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmedTitle.isEmpty && trimmedBody.isEmpty) ? snapshot.identifier : nil
        }
    }
}

/// Test-friendly snapshot of the fields we filter on. Initialized from a
/// `UNNotification` at runtime; constructed directly in unit tests since
/// `UNNotification`'s designated initializer isn't accessible.
struct DeliveredNotificationSnapshot {
    let identifier: String
    let title: String
    let body: String
    let categoryIdentifier: String
    let userInfo: [AnyHashable: Any]

    init(from notification: UNNotification) {
        self.identifier = notification.request.identifier
        self.title = notification.request.content.title
        self.body = notification.request.content.body
        self.categoryIdentifier = notification.request.content.categoryIdentifier
        self.userInfo = notification.request.content.userInfo
    }

    init(
        identifier: String,
        title: String,
        body: String,
        categoryIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.categoryIdentifier = categoryIdentifier
        self.userInfo = userInfo
    }
}
