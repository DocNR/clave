import Foundation
import NostrSDK
import Observation
import UIKit

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

    /// Fetch kind 0 profile from relay. Call once on appear, throttled by cache age.
    func fetchProfileIfNeeded() {
        guard !signerPubkeyHex.isEmpty else { return }

        // Only refetch if cache is older than 1 hour
        if let existing = profile, Date().timeIntervalSince1970 - existing.fetchedAt < 3600 { return }

        Task {
            do {
                let relay = LightRelay(url: SharedConstants.relayURL)
                try await relay.connect(timeout: 5.0)

                let filter: [String: Any] = [
                    "kinds": [0],
                    "authors": [signerPubkeyHex],
                    "limit": 1
                ]

                let events = try await relay.fetchEvents(filter: filter, timeout: 10.0)
                relay.disconnect()

                guard let event = events.first,
                      let content = event["content"] as? String,
                      let contentData = content.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any] else {
                    return
                }

                let displayName = (json["display_name"] as? String) ?? (json["name"] as? String)
                let pictureURL = json["picture"] as? String

                let cached = CachedProfile(
                    displayName: displayName,
                    pictureURL: pictureURL,
                    fetchedAt: Date().timeIntervalSince1970
                )

                await MainActor.run {
                    self.profile = cached
                    self.saveCachedProfile(cached)
                }

                if let pic = pictureURL, !pic.isEmpty {
                    await cacheImage(from: pic)
                }
            } catch {
                // Silently fail — keep showing gradient avatar + npub
            }
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
    }

    func generateKey() throws {
        let keys = Keys.generate()
        let bech32 = try keys.secretKey().toBech32()
        try SharedKeychain.saveNsec(bech32)
        signerPubkeyHex = keys.publicKey().toHex()
        SharedConstants.sharedDefaults.set(signerPubkeyHex, forKey: SharedConstants.signerPubkeyHexKey)
        isKeyImported = true
    }

    func deleteKey() {
        SharedKeychain.deleteNsec()
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.signerPubkeyHexKey)
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.cachedProfileKey)
        SharedStorage.clearActivityLog()
        SharedStorage.clearPendingRequests()
        SharedStorage.unpairAllClients()
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

    func registerWithProxy(completion: ((Bool, String) -> Void)? = nil) {
        // Reload token from SharedDefaults in case it arrived after loadState()
        let token = SharedConstants.sharedDefaults.string(forKey: SharedConstants.deviceTokenKey) ?? ""
        if !token.isEmpty && deviceToken.isEmpty { deviceToken = token }

        guard !deviceToken.isEmpty else {
            completion?(false, "No device token")
            return
        }
        let proxyURL = SharedConstants.sharedDefaults.string(forKey: SharedConstants.proxyURLKey)
            ?? SharedConstants.defaultProxyURL
        guard let url = URL(string: "\(proxyURL)/register") else {
            completion?(false, "Invalid proxy URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let secret = SharedConstants.sharedDefaults.string(forKey: SharedConstants.proxyRegisterSecretKey)
            ?? SharedConstants.defaultProxyRegisterSecret
        if !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": deviceToken])

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    print("[Clave] Registered with proxy")
                    completion?(true, "Registered")
                } else if let http = response as? HTTPURLResponse {
                    print("[Clave] Proxy registration failed: \(http.statusCode)")
                    completion?(false, "Failed: HTTP \(http.statusCode)")
                } else {
                    completion?(false, error?.localizedDescription ?? "Connection failed")
                }
            }
        }.resume()
    }
}
