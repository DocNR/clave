import UserNotifications
import os.log

private let logger = Logger(subsystem: "dev.nostr.clave.ClaveNSE", category: "signing")

private struct SigningResult {
    enum Status {
        case success
        case pending(clientPubkey: String, eventKind: Int?)
        case error(String)
        case noEvents
    }
    let status: Status
}

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
            let result = await handleSigningRequest(userInfo: request.content.userInfo)
            deliverContent(result: result)
        }
    }

    private func deliverContent(result: SigningResult) {
        deliverLock.lock()
        defer { deliverLock.unlock() }
        guard !hasDelivered else { return }
        hasDelivered = true

        guard let content = bestAttemptContent else {
            contentHandler?(UNMutableNotificationContent())
            return
        }

        switch result.status {
        case .error(let message):
            content.title = "Signing Failed"
            content.body = message
            // Override payload-level passive so real errors still banner-pop.
            // The proxy sets interruption-level: passive on the push payload to
            // suppress success notifications; we need to restore active interruption
            // here so users actually see when something goes wrong.
            content.interruptionLevel = .active
            contentHandler?(content)

        case .pending(let clientPubkey, let eventKind):
            let clientName = SharedStorage.getClientPermissions(for: clientPubkey)?.name
                ?? String(clientPubkey.prefix(8))
            let kindDesc = eventKind.map { KnownKinds.label(for: $0) } ?? "event"
            content.title = "Approve Signing Request"
            content.body = "\(clientName) wants to sign \(kindDesc)"
            content.interruptionLevel = .active
            contentHandler?(content)

        case .success, .noEvents:
            content.title = ""
            content.body = ""
            content.sound = nil
            content.badge = nil
            content.interruptionLevel = .passive
            content.relevanceScore = 0
            contentHandler?(content)
        }
    }

    private func handleSigningRequest(userInfo: [AnyHashable: Any]) async -> SigningResult {
        guard let nsec = SharedKeychain.loadNsec() else {
            // No key set up yet — silently drop. User hasn't onboarded; they
            // should never see a "Signing Failed" banner for events that aren't
            // for them. The proxy broadcasts pushes to all registered tokens
            // (multi-signer refactor is a separate backlog item).
            logger.notice("[ClaveNSE] No nsec in Keychain — silently dropping push")
            return SigningResult(status: .noEvents)
        }

        let privateKey: Data
        do {
            privateKey = try Bech32.decodeNsec(nsec)
        } catch {
            logger.error("[ClaveNSE] Failed to decode nsec: \(error.localizedDescription)")
            return SigningResult(status: .error("Invalid signer key"))
        }

        let signerPubkey: String
        do {
            signerPubkey = try LightEvent.pubkeyHex(from: privateKey)
        } catch {
            return SigningResult(status: .error("Failed to derive pubkey"))
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

            if events.isEmpty {
                return SigningResult(status: .noEvents)
            }

            let processedKey = "processedEventIDs"
            var processedIDs = Set(SharedConstants.sharedDefaults.stringArray(forKey: processedKey) ?? [])

            var lastError: String? = nil
            var handledCount = 0
            var lastPendingPubkey: String? = nil
            var lastPendingKind: Int? = nil

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
                    // Decrypt failures mean "not for us" — skip silently
                    if result.status == "error" && result.errorMessage == "Decrypt failed" {
                        continue
                    }
                    handledCount += 1
                    if result.status == "error" {
                        lastError = result.errorMessage
                    } else if result.status == "pending" {
                        lastPendingPubkey = eventPubkey
                        // Extract the kind from the request event's content if available
                        if let kindVal = event["kind"] as? Int {
                            lastPendingKind = kindVal
                        }
                    }
                } catch {
                    // Treat errors as non-fatal — event may not be for us
                    processedIDs.insert(eventId)
                    logger.notice("[ClaveNSE] Skipping event: \(error.localizedDescription)")
                }
            }

            let trimmed = Array(processedIDs.suffix(50))
            SharedConstants.sharedDefaults.set(trimmed, forKey: processedKey)

            logger.notice("[ClaveNSE] Handled \(handledCount) new requests, skipped \(events.count - handledCount) duplicates")

            if handledCount == 0 {
                return SigningResult(status: .noEvents)
            } else if let pendingPubkey = lastPendingPubkey {
                return SigningResult(status: .pending(clientPubkey: pendingPubkey, eventKind: lastPendingKind))
            } else if let error = lastError {
                return SigningResult(status: .error(error))
            } else {
                return SigningResult(status: .success)
            }

        } catch {
            logger.error("[ClaveNSE] Error: \(error.localizedDescription)")
            return SigningResult(status: .error("Relay error: \(error.localizedDescription)"))
        }
    }

    override func serviceExtensionTimeWillExpire() {
        logger.notice("[ClaveNSE] Time will expire")
        deliverContent(result: SigningResult(status: .error("Signing timed out")))
    }
}
