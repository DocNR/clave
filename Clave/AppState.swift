import Foundation
import CryptoKit
import NostrSDK
import Observation
import UIKit

enum ClaveError: LocalizedError {
    case noSignerKey
    case noRelay
    case serializationFailed
    case invalidPubkey

    var errorDescription: String? {
        switch self {
        case .noSignerKey: return "No signer key configured"
        case .noRelay: return "No relay specified"
        case .serializationFailed: return "Failed to build response"
        case .invalidPubkey: return "Invalid client public key"
        }
    }
}

struct CachedProfile: Codable {
    var displayName: String?
    var pictureURL: String?
    var fetchedAt: Double  // timeIntervalSince1970
}

@Observable
final class AppState {
    var isKeyImported = false
    var signerPubkeyHex = ""
    var deviceToken = ""
    var pendingRequests: [PendingRequest] = []
    var profile: CachedProfile?
    var profileImage: UIImage?

    var npub: String {
        guard !signerPubkeyHex.isEmpty,
              let pubkey = try? PublicKey.parse(publicKey: signerPubkeyHex) else { return "" }
        return (try? pubkey.toBech32()) ?? ""
    }

    var bunkerSecret = ""

    var bunkerURI: String {
        guard !signerPubkeyHex.isEmpty else { return "" }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":/")
        let relay = SharedConstants.relayURL
            .addingPercentEncoding(withAllowedCharacters: allowed) ?? SharedConstants.relayURL
        // Always read the latest secret from SharedStorage (NSE may have rotated it)
        let currentSecret = SharedStorage.getBunkerSecret()
        return "bunker://\(signerPubkeyHex)?relay=\(relay)&secret=\(currentSecret)"
    }

    func loadState() {
        if let nsec = SharedKeychain.loadNsec(),
           let keys = try? Keys.parse(secretKey: nsec) {
            signerPubkeyHex = keys.publicKey().toHex()
            isKeyImported = true
        }
        deviceToken = SharedConstants.sharedDefaults.string(forKey: SharedConstants.deviceTokenKey) ?? ""
        bunkerSecret = SharedStorage.getBunkerSecret()
        loadCachedProfile()
    }

    private func loadCachedProfile() {
        guard let data = SharedConstants.sharedDefaults.data(forKey: SharedConstants.cachedProfileKey),
              let cached = try? JSONDecoder().decode(CachedProfile.self, from: data) else { return }
        profile = cached

        if let imageData = try? Data(contentsOf: cachedImageURL),
           let image = UIImage(data: imageData) {
            profileImage = image
        }
    }

    private func saveCachedProfile(_ profile: CachedProfile) {
        if let data = try? JSONEncoder().encode(profile) {
            SharedConstants.sharedDefaults.set(data, forKey: SharedConstants.cachedProfileKey)
        }
    }

    private var cachedImageURL: URL {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedConstants.appGroup)!
        return container.appendingPathComponent("profile_image.jpg")
    }

    private func cacheImage(from urlString: String) async {
        guard let url = URL(string: urlString) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else { return }
            try data.write(to: cachedImageURL)
            await MainActor.run {
                self.profileImage = image
            }
        } catch {
            // Silently fail
        }
    }

    /// Fetch kind 0 profile from multiple relays in parallel. First valid result wins.
    func fetchProfileIfNeeded() {
        guard !signerPubkeyHex.isEmpty else { return }

        // Only refetch if cache is older than 1 hour
        if let existing = profile, Date().timeIntervalSince1970 - existing.fetchedAt < 3600 { return }

        let relays = [
            "wss://relay.powr.build",
            "wss://relay.damus.io",
            "wss://nos.lol",
            "wss://relay.primal.net",
            "wss://purplepag.es"
        ]

        Task {
            await withTaskGroup(of: CachedProfile?.self) { group in
                for url in relays {
                    group.addTask { [signerPubkeyHex] in
                        await Self.fetchProfile(from: url, pubkey: signerPubkeyHex)
                    }
                }

                // Pick the most-recent profile across all relays (kind:0 is replaceable, latest wins)
                var newest: CachedProfile?
                for await result in group {
                    guard let result else { continue }
                    if newest == nil { newest = result; continue }
                    // Prefer the one with a picture if the other doesn't have one
                    if newest?.pictureURL == nil && result.pictureURL != nil { newest = result }
                }

                guard let cached = newest else { return }

                await MainActor.run {
                    self.profile = cached
                    self.saveCachedProfile(cached)
                }

                if let pic = cached.pictureURL, !pic.isEmpty {
                    await cacheImage(from: pic)
                }
            }
        }
    }

    private static func fetchProfile(from relayURL: String, pubkey: String) async -> CachedProfile? {
        do {
            let relay = LightRelay(url: relayURL)
            try await relay.connect(timeout: 5.0)
            defer { relay.disconnect() }

            let filter: [String: Any] = [
                "kinds": [0],
                "authors": [pubkey],
                "limit": 1
            ]

            let events = try await relay.fetchEvents(filter: filter, timeout: 5.0)

            guard let event = events.first,
                  let content = event["content"] as? String,
                  let contentData = content.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any] else {
                return nil
            }

            let displayName = (json["display_name"] as? String) ?? (json["name"] as? String)
            let pictureURL = json["picture"] as? String

            // Skip empty profiles (no name AND no picture)
            if (displayName?.isEmpty ?? true) && (pictureURL?.isEmpty ?? true) {
                return nil
            }

            return CachedProfile(
                displayName: displayName,
                pictureURL: pictureURL,
                fetchedAt: Date().timeIntervalSince1970
            )
        } catch {
            return nil
        }
    }

    func rotateBunkerSecret() {
        bunkerSecret = SharedStorage.rotateBunkerSecret()
    }

    func importKey(nsec: String) throws {
        let keys = try Keys.parse(secretKey: nsec.trimmingCharacters(in: .whitespacesAndNewlines))
        let bech32 = try keys.secretKey().toBech32()
        try SharedKeychain.saveNsec(bech32)
        signerPubkeyHex = keys.publicKey().toHex()
        SharedConstants.sharedDefaults.set(signerPubkeyHex, forKey: SharedConstants.signerPubkeyHexKey)
        isKeyImported = true
        // Now that a key exists, register with the proxy so we start receiving
        // push-wake for signing requests. AppDelegate skips this on launch when
        // no key is present.
        registerWithProxy()
    }

    func generateKey() throws {
        let keys = Keys.generate()
        let bech32 = try keys.secretKey().toBech32()
        try SharedKeychain.saveNsec(bech32)
        signerPubkeyHex = keys.publicKey().toHex()
        SharedConstants.sharedDefaults.set(signerPubkeyHex, forKey: SharedConstants.signerPubkeyHexKey)
        isKeyImported = true
        registerWithProxy()
    }

    func deleteKey() {
        // Unregister BEFORE wiping the keychain — needs the nsec to sign the NIP-98 header.
        unregisterWithProxy()
        SharedKeychain.deleteNsec()
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.signerPubkeyHexKey)
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.cachedProfileKey)
        SharedStorage.clearActivityLog()
        SharedStorage.clearPendingRequests()
        SharedStorage.unpairAllClients()
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.clientPermissionsKey)
        // Clear connected clients
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.connectedClientsKey)
        // Rotate bunker secret for the new key
        _ = SharedStorage.rotateBunkerSecret()
        // Clear cached profile image
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedConstants.appGroup)
        if let imageURL = container?.appendingPathComponent("profile_image.jpg") {
            try? FileManager.default.removeItem(at: imageURL)
        }
        signerPubkeyHex = ""
        profile = nil
        profileImage = nil
        pendingRequests = []
        isKeyImported = false
    }

    func refreshPendingRequests() {
        pendingRequests = SharedStorage.getPendingRequests()
    }

    /// Reload the bunker secret from SharedDefaults (picks up NSE-rotated secrets)
    func refreshBunkerSecret() {
        bunkerSecret = SharedStorage.getBunkerSecret()
    }

    /// Approve a pending request: sign and publish the response from the app.
    func approvePendingRequest(_ request: PendingRequest) async -> Bool {
        guard let nsec = SharedKeychain.loadNsec() else { return false }

        let privateKey: Data
        do {
            privateKey = try Bech32.decodeNsec(nsec)
        } catch {
            return false
        }

        // Reconstruct the request event dict from stored JSON
        guard let data = request.requestEventJSON.data(using: .utf8),
              let requestEvent = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        do {
            let result = try await LightSigner.handleRequest(privateKey: privateKey, requestEvent: requestEvent, skipProtection: true)
            SharedStorage.removePendingRequest(id: request.id)
            refreshPendingRequests()
            return result.status == "signed"
        } catch {
            return false
        }
    }

    func denyPendingRequest(_ request: PendingRequest) {
        SharedStorage.removePendingRequest(id: request.id)
        refreshPendingRequests()
    }

    /// Perform the nostrconnect:// handshake across all relays listed in the URI.
    /// Why multi-relay: the client (per NIP-46) subscribes on every relay in its URI;
    /// if we publish to only one and that relay drops the ephemeral kind:24133,
    /// the client never sees our response. Publishing to all is best-effort — we
    /// don't fail if some relays reject or are unreachable, we just need at least one.
    func handleNostrConnect(
        parsedURI: NostrConnectParser.ParsedURI,
        permissions: ClientPermissions
    ) async throws {
        guard let nsec = SharedKeychain.loadNsec() else {
            throw ClaveError.noSignerKey
        }
        let privateKey = try Bech32.decodeNsec(nsec)
        let signerPubkey = try LightEvent.pubkeyHex(from: privateKey)

        // Save client permissions
        SharedStorage.saveClientPermissions(permissions)

        guard !parsedURI.relays.isEmpty else {
            throw ClaveError.noRelay
        }
        guard let clientPubkeyData = Data(hexString: parsedURI.clientPubkey) else {
            throw ClaveError.invalidPubkey
        }

        // Connect to every URI relay in parallel, best-effort.
        let connectedRelays = await connectToRelays(urls: parsedURI.relays, timeout: 10.0)
        defer {
            for relay in connectedRelays { relay.disconnect() }
        }

        // If zero relays connected, log the failure so the user sees it, then throw.
        if connectedRelays.isEmpty {
            let entry = ActivityEntry(
                id: UUID().uuidString,
                method: "connect",
                eventKind: nil,
                clientPubkey: parsedURI.clientPubkey,
                timestamp: Date().timeIntervalSince1970,
                status: "error",
                errorMessage: "Could not connect to any relay"
            )
            SharedStorage.logActivity(entry)
            throw ClaveError.noRelay
        }

        // Publish connect response with retry — ephemeral events (kind 24133) aren't
        // stored by relays, so the client must be subscribed at the moment we publish.
        // Retry up to 3 times with 2s gaps, stopping early if we hear back from the client.
        var handshakeComplete = false
        var activityLogged = false

        for _ in 1...3 {
            // Build a fresh event each attempt (new created_at = new event ID)
            let responseId = UUID().uuidString
            let responseDict: [String: Any] = ["id": responseId, "result": parsedURI.secret]
            guard let responseData = try? JSONSerialization.data(withJSONObject: responseDict),
                  let responseJSON = String(data: responseData, encoding: .utf8) else {
                continue
            }
            let freshEncrypted = try LightCrypto.nip44Encrypt(
                privateKey: privateKey,
                publicKey: clientPubkeyData,
                plaintext: responseJSON
            )
            let connectEvent = try LightEvent.sign(
                privateKey: privateKey,
                kind: 24133,
                content: freshEncrypted,
                tags: [["p", parsedURI.clientPubkey]]
            )

            if let eventData = connectEvent.toJSON().data(using: .utf8),
               let eventDict = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any] {
                let acceptedCount = await publishEventToRelays(connectedRelays, event: eventDict)

                if !activityLogged {
                    let success = acceptedCount > 0
                    let entry = ActivityEntry(
                        id: UUID().uuidString,
                        method: "connect",
                        eventKind: nil,
                        clientPubkey: parsedURI.clientPubkey,
                        timestamp: Date().timeIntervalSince1970,
                        status: success ? "signed" : "error",
                        errorMessage: success ? nil : "All relays rejected connect response"
                    )
                    SharedStorage.logActivity(entry)
                    activityLogged = true
                }
            }

            // Wait then check for client response across all connected relays.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let now = Int(Date().timeIntervalSince1970)
            let listenFilter: [String: Any] = [
                "kinds": [24133],
                "#p": [signerPubkey],
                "since": now - 10,
                "limit": 10
            ]
            let events = await fetchEventsFromRelays(connectedRelays, filter: listenFilter, timeout: 3.0)
            var seenEventIds = Set<String>()
            for event in events {
                guard let eventId = event["id"] as? String, seenEventIds.insert(eventId).inserted else { continue }
                guard let pubkey = event["pubkey"] as? String,
                      pubkey == parsedURI.clientPubkey else { continue }
                let _ = try? await LightSigner.handleRequest(
                    privateKey: privateKey,
                    requestEvent: event,
                    responseRelays: connectedRelays
                )
                handshakeComplete = true
            }

            if handshakeComplete {
                break
            }
        }
    }

    func registerWithProxy(completion: ((Bool, String) -> Void)? = nil) {
        // Reload token from SharedDefaults in case it arrived after loadState()
        let token = SharedConstants.sharedDefaults.string(forKey: SharedConstants.deviceTokenKey) ?? ""
        if !token.isEmpty && deviceToken.isEmpty { deviceToken = token }

        guard !deviceToken.isEmpty else {
            completion?(false, "No device token")
            return
        }

        guard let nsec = SharedKeychain.loadNsec() else {
            completion?(false, "No signer key")
            return
        }

        let privateKey: Data
        do {
            privateKey = try Bech32.decodeNsec(nsec)
        } catch {
            completion?(false, "Invalid signer key")
            return
        }

        let proxyURL = SharedConstants.sharedDefaults.string(forKey: SharedConstants.proxyURLKey)
            ?? SharedConstants.defaultProxyURL
        let registerURL = "\(proxyURL)/register"
        guard let url = URL(string: registerURL) else {
            completion?(false, "Invalid proxy URL")
            return
        }

        let bodyDict = ["token": deviceToken]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: bodyDict) else {
            completion?(false, "Body serialization failed")
            return
        }
        let bodyHash = SHA256.hash(data: bodyData).map { String(format: "%02x", $0) }.joined()

        let authHeader: String
        do {
            authHeader = try LightEvent.signNip98(
                privateKey: privateKey,
                url: registerURL,
                method: "POST",
                bodySha256Hex: bodyHash
            )
        } catch {
            completion?(false, "Auth signing failed: \(error.localizedDescription)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader, forHTTPHeaderField: "X-Clave-Auth")
        request.httpBody = bodyData

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    completion?(true, "Registered")
                } else if let http = response as? HTTPURLResponse {
                    completion?(false, "Failed: HTTP \(http.statusCode)")
                } else {
                    completion?(false, error?.localizedDescription ?? "Connection failed")
                }
            }
        }.resume()
    }

    /// Unregister the current device token with the proxy. Called from `deleteKey()`
    /// before clearing the keychain, so we still have access to the nsec for NIP-98 signing.
    /// Fire-and-forget — we don't block deleteKey on the result.
    func unregisterWithProxy() {
        let token = SharedConstants.sharedDefaults.string(forKey: SharedConstants.deviceTokenKey) ?? ""
        guard !token.isEmpty else { return }

        guard let nsec = SharedKeychain.loadNsec() else { return }
        let privateKey: Data
        do {
            privateKey = try Bech32.decodeNsec(nsec)
        } catch {
            return
        }

        let proxyURL = SharedConstants.sharedDefaults.string(forKey: SharedConstants.proxyURLKey)
            ?? SharedConstants.defaultProxyURL
        let unregisterURL = "\(proxyURL)/unregister"
        guard let url = URL(string: unregisterURL) else { return }

        let bodyDict = ["token": token]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: bodyDict) else { return }
        let bodyHash = SHA256.hash(data: bodyData).map { String(format: "%02x", $0) }.joined()

        let authHeader: String
        do {
            authHeader = try LightEvent.signNip98(
                privateKey: privateKey,
                url: unregisterURL,
                method: "POST",
                bodySha256Hex: bodyHash
            )
        } catch {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader, forHTTPHeaderField: "X-Clave-Auth")
        request.httpBody = bodyData

        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    // MARK: - Multi-relay helpers (nostrconnect handshake)

    /// Connect to multiple relays in parallel, best-effort.
    /// Returns only the relays that connected successfully within the timeout.
    /// Failures are silently dropped so one unreachable relay never blocks the others.
    private func connectToRelays(urls: [String], timeout: TimeInterval) async -> [LightRelay] {
        await withTaskGroup(of: LightRelay?.self) { group in
            for url in urls {
                group.addTask {
                    let relay = LightRelay(url: url)
                    do {
                        try await relay.connect(timeout: timeout)
                        return relay
                    } catch {
                        return nil
                    }
                }
            }
            var connected: [LightRelay] = []
            for await maybe in group {
                if let relay = maybe { connected.append(relay) }
            }
            return connected
        }
    }

    /// Publish the same event to all connected relays in parallel.
    /// Returns the number of relays that returned `OK true`.
    private func publishEventToRelays(_ relays: [LightRelay], event: [String: Any]) async -> Int {
        await withTaskGroup(of: Bool.self) { group in
            for relay in relays {
                group.addTask {
                    (try? await relay.publishEvent(event: event)) ?? false
                }
            }
            var accepted = 0
            for await ok in group {
                if ok { accepted += 1 }
            }
            return accepted
        }
    }

    /// Fetch events matching the filter from all connected relays in parallel.
    /// Aggregates results; duplicates by event id are NOT removed (caller should handle).
    private func fetchEventsFromRelays(
        _ relays: [LightRelay],
        filter: [String: Any],
        timeout: TimeInterval
    ) async -> [[String: Any]] {
        await withTaskGroup(of: [[String: Any]].self) { group in
            for relay in relays {
                group.addTask {
                    (try? await relay.fetchEvents(filter: filter, timeout: timeout)) ?? []
                }
            }
            var all: [[String: Any]] = []
            for await events in group {
                all.append(contentsOf: events)
            }
            return all
        }
    }

    // MARK: - Test-only shims

    #if DEBUG
    func _testOnlyConnectToRelays(urls: [String], timeout: TimeInterval) async -> [LightRelay] {
        await connectToRelays(urls: urls, timeout: timeout)
    }
    func _testOnlyPublishEventToRelays(_ relays: [LightRelay], event: [String: Any]) async -> Int {
        await publishEventToRelays(relays, event: event)
    }
    func _testOnlyFetchEventsFromRelays(_ relays: [LightRelay], filter: [String: Any], timeout: TimeInterval) async -> [[String: Any]] {
        await fetchEventsFromRelays(relays, filter: filter, timeout: timeout)
    }
    #endif
}
