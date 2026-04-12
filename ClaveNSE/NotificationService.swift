import UserNotifications
import os.log

private let logger = Logger(subsystem: "dev.nostr.clave.ClaveNSE", category: "signing")

class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?
    private var hasDelivered = false
    private let deliverLock = NSLock()

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        logger.notice("[ClaveNSE] didReceive called")

        Task {
            let error = await handleSigningRequest(userInfo: request.content.userInfo)
            deliverContent(error: error)
        }
    }

    /// Suppress notification on success, show error on failure
    private func deliverContent(error: String? = nil) {
        deliverLock.lock()
        defer { deliverLock.unlock() }
        guard !hasDelivered else { return }
        hasDelivered = true

        if let error = error, let content = bestAttemptContent {
            content.title = "Signing Failed"
            content.body = error
            contentHandler?(content)
        } else if let content = bestAttemptContent {
            // Success — clear the alert to suppress notification
            content.title = ""
            content.body = ""
            content.sound = nil
            content.badge = nil
            contentHandler?(content)
        } else {
            let empty = UNMutableNotificationContent()
            contentHandler?(empty)
        }
    }

    /// Returns nil on success, error string on failure
    private func handleSigningRequest(userInfo: [AnyHashable: Any]) async -> String? {
        guard let nsec = SharedKeychain.loadNsec() else {
            logger.error("[ClaveNSE] No nsec in Keychain")
            return "No signer key configured"
        }

        let privateKey: Data
        do {
            privateKey = try Bech32.decodeNsec(nsec)
        } catch {
            logger.error("[ClaveNSE] Failed to decode nsec: \(error.localizedDescription)")
            return "Invalid signer key"
        }

        let signerPubkey: String
        do {
            signerPubkey = try LightEvent.pubkeyHex(from: privateKey)
        } catch {
            return "Failed to derive pubkey"
        }

        let relayUrlString = (userInfo["relay_url"] as? String) ?? SharedConstants.relayURL

        do {
            let relay = LightRelay(url: relayUrlString)
            try await relay.connect()

            let now = Int(Date().timeIntervalSince1970)
            let filter: [String: Any] = [
                "kinds": [24133],
                "since": now - 60,
                "limit": 5
            ]

            var events = try await relay.fetchEvents(filter: filter, timeout: 10.0)

            if events.isEmpty {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let retryFilter: [String: Any] = [
                    "kinds": [24133],
                    "since": now - 120,
                    "limit": 5
                ]
                events = try await relay.fetchEvents(filter: retryFilter, timeout: 10.0)
            }

            relay.disconnect()

            if events.isEmpty {
                return "No signing requests found"
            }

            // Track processed event IDs to avoid duplicate handling
            let processedKey = "processedEventIDs"
            var processedIDs = Set(SharedConstants.sharedDefaults.stringArray(forKey: processedKey) ?? [])

            var lastError: String? = nil
            var handledCount = 0
            for event in events {
                guard let eventPubkey = event["pubkey"] as? String,
                      eventPubkey != signerPubkey,
                      let eventId = event["id"] as? String,
                      !processedIDs.contains(eventId) else { continue }

                do {
                    try await LightSigner.handleRequest(
                        privateKey: privateKey,
                        requestEvent: event
                    )
                    processedIDs.insert(eventId)
                    handledCount += 1
                } catch {
                    lastError = error.localizedDescription
                    logger.error("[ClaveNSE] Failed: \(error.localizedDescription)")
                }
            }

            // Save processed IDs (keep last 50 to prevent unbounded growth)
            let trimmed = Array(processedIDs.suffix(50))
            SharedConstants.sharedDefaults.set(trimmed, forKey: processedKey)

            logger.notice("[ClaveNSE] Handled \(handledCount) new requests, skipped \(events.count - handledCount) duplicates")

            return lastError

        } catch {
            logger.error("[ClaveNSE] Error: \(error.localizedDescription)")
            return "Relay error: \(error.localizedDescription)"
        }
    }

    override func serviceExtensionTimeWillExpire() {
        logger.notice("[ClaveNSE] Time will expire")
        deliverContent(error: "Signing timed out")
    }
}
