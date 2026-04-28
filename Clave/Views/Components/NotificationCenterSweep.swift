import Foundation
import UserNotifications
import os.log

private let logger = Logger(subsystem: "dev.nostr.clave", category: "nc-sweep")

/// Removes blank delivered notifications from Notification Center. "Blank"
/// means BOTH title AND body are empty after trimming whitespace. Two paths
/// produce these:
///
///   1. NSE silent-success / `.noEvents` deliberately sets title/body to ""
///      and `.passive` interruption (`ClaveNSE/NotificationService.swift:71-78`).
///      NSE's own `removeDeliveredNotifications` immediately after
///      `contentHandler` is racy — NSE process often exits before iOS commits
///      the notification, so the remove no-ops.
///
///   2. NSE doesn't run at all (cold-launch race, 30s budget exceeded, or
///      iOS skips spawning it under load). iOS then renders the proxy's
///      original APNs payload — which uses single SPACE characters
///      (`relay-proxy/proxy.js` `alert: { title: " ", body: " " }`) so NSE
///      has something to override. A single-space title is NOT `.isEmpty`,
///      hence the trim.
///
/// Locally-scheduled pending-approval banners ("Approve Signing Request") and
/// sign-failure banners ("Signing Failed") have non-empty title AND non-empty
/// body and are preserved.
///
/// Free function rather than a method so both `MainTabView` (scenePhase
/// observer) and `ForegroundRelaySubscription` (L1 event dispatch) can call
/// it without a shared owner.
func sweepBlankNotifications() {
    let center = UNUserNotificationCenter.current()
    center.getDeliveredNotifications { delivered in
        let blankIds = delivered
            .filter { notif in
                let trimmedTitle = notif.request.content.title
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedBody = notif.request.content.body
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmedTitle.isEmpty && trimmedBody.isEmpty
            }
            .map { $0.request.identifier }
        guard !blankIds.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: blankIds)
        logger.notice("[NC-Sweep] Removed \(blankIds.count, privacy: .public) blank notification(s)")
    }
}
