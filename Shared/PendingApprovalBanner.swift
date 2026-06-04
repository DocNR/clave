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
    /// pending-approval pushes (title varies by method, body has the v3
    /// kind + scope + tier banner when present, `.active` interruption).
    ///
    /// `method` defaults to `"sign_event"` to preserve back-compat for
    /// older callers (and the LockScreenActionRoutingTests fixture); for
    /// v3 paths, supply method = `"nip44v3_encrypt"` / `"nip44v3_decrypt"`
    /// + v3Kind + v3Scope so the body renders the same way the foreground
    /// `MainTabView.alertMessage` does.
    ///
    /// Idempotent on identifier collisions — UNUserNotificationCenter
    /// replaces an existing pending request with the same identifier.
    /// We pass the request id so denying/approving the same request won't
    /// stack banners.
    static func schedule(
        requestId: String,
        clientPubkey: String,
        method: String = "sign_event",
        eventKind: Int?,
        v3Kind: UInt32? = nil,
        v3Scope: String? = nil
    ) {
        let content = makeContent(
            requestId: requestId,
            clientPubkey: clientPubkey,
            method: method,
            eventKind: eventKind,
            v3Kind: v3Kind,
            v3Scope: v3Scope
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
        method: String = "sign_event",
        eventKind: Int?,
        v3Kind: UInt32? = nil,
        v3Scope: String? = nil
    ) -> UNMutableNotificationContent {
        let clientName = SharedStorage.getClientPermissions(for: clientPubkey)?.name
            ?? "Client …\(clientPubkey.suffix(8))"

        let content = UNMutableNotificationContent()
        content.title = pendingTitle(method: method)
        content.body = pendingBody(
            clientName: clientName,
            method: method,
            eventKind: eventKind,
            v3Kind: v3Kind,
            v3Scope: v3Scope
        )
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

    /// Method-aware title. Mirrors `MainTabView.alertTitle` (minus the
    /// chain-position suffix — chain state isn't available in NSE, and
    /// the foreground L1 path schedules the banner BEFORE
    /// MainTabView's alert renders, so consistency on the bare base is
    /// what matters). Shared with NSE so background-push and
    /// L1-foreground banners render identically.
    static func pendingTitle(method: String) -> String {
        switch method {
        case "sign_event":
            return "Approve Signing Request"
        case "nip04_encrypt", "nip44_encrypt":
            return "Approve Encryption Request"
        case "nip04_decrypt", "nip44_decrypt":
            return "Approve Decryption Request"
        case "nip44v3_encrypt":
            return "Approve v3 Encryption"
        case "nip44v3_decrypt":
            return "Approve v3 Decryption"
        default:
            return "Approve Request"
        }
    }

    /// Method-aware body. Mirrors `MainTabView.alertMessage` line-by-line
    /// for v3 requests: client → kind label → scope quote → tier warning.
    /// iOS notifications have no per-line styling, so lines join with `\n`
    /// and tier prefixes use the same warning glyphs.
    static func pendingBody(
        clientName: String,
        method: String,
        eventKind: Int?,
        v3Kind: UInt32?,
        v3Scope: String?
    ) -> String {
        var lines: [String] = []
        lines.append("From: \(clientName)")

        if method == "sign_event", let kind = eventKind {
            lines.append(KnownKinds.label(for: kind))
        } else if let v3Kind {
            lines.append(KnownKinds.label(for: Int(v3Kind)))
            if let scope = v3Scope, !scope.isEmpty {
                lines.append("Scope: \u{201C}\(scope)\u{201D}")
            }
            switch KnownKinds.sensitivityTier(for: Int(v3Kind)) {
            case .tierS:
                lines.append("⚠️ Highly sensitive — only approve if you initiated this right now")
            case .tierA:
                lines.append("⚠️ Sensitive context")
            case .tierB, .normal:
                break
            }
        } else {
            lines.append("Method: \(method)")
        }
        return lines.joined(separator: "\n")
    }

    /// Removes the delivered/pending banner for a given request id. Called when
    /// the user approves, denies, or the TTL purge expires a pending request,
    /// so the banner doesn't linger in Notification Center.
    ///
    /// Three flavors of cleanup happen in this call:
    ///
    ///   1. Locally-scheduled banners — identifier `"pending-approval-<requestId>"`.
    ///      The synchronous remove below handles these.
    ///   2. NSE-delivered via APNs (`ClaveNSE/NotificationService.swift`
    ///      `.pending` case). These use the APNs request identifier (proxy-
    ///      assigned, not our prefix), so we match by `categoryIdentifier`
    ///      + `userInfo.pendingRequestId` instead.
    ///   3. Blank notifications from prior NSE silent-success wakes. The
    ///      lock-screen Approve / Deny action handler runs the main app in
    ///      *background* (action options are `.authenticationRequired` only —
    ///      see `ClaveApp.swift:79`), which means `scenePhase .active` never
    ///      fires and `MainTabView`'s `sweepBlankNotifications()` doesn't run.
    ///      Without sweeping blanks here, a blank from an earlier wake would
    ///      stay in NC after the user took an action. Since we're already
    ///      enumerating delivered notifications for (2), the blank-filter
    ///      add is one extra line.
    static func clear(requestId: String) {
        let center = UNUserNotificationCenter.current()
        let localIdentifier = "pending-approval-\(requestId)"
        center.removePendingNotificationRequests(withIdentifiers: [localIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [localIdentifier])

        Task {
            let delivered = await center.deliveredNotifications()
            let snapshots = delivered.map(DeliveredNotificationSnapshot.init(from:))
            let nseIdentifiers = nseDeliveredIds(forRequest: requestId, in: snapshots)
            let blankIdentifiers = blankDeliveredIds(in: snapshots)
            let toRemove = nseIdentifiers + blankIdentifiers
            guard !toRemove.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: toRemove)
            logger.notice("[Banner] Cleared \(nseIdentifiers.count, privacy: .public) NSE banner(s) + \(blankIdentifiers.count, privacy: .public) blank(s) for request \(requestId.prefix(8), privacy: .public)")
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
