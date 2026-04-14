import Foundation
import os.log

private let logger = Logger(subsystem: "dev.nostr.clave", category: "storage")

enum SharedStorage {

    private static var defaults: UserDefaults { SharedConstants.sharedDefaults }

    // MARK: - Activity Log

    static func logActivity(_ entry: ActivityEntry) {
        var log = getActivityLog()
        let before = log.count
        log.insert(entry, at: 0)
        if log.count > 200 { log = Array(log.prefix(200)) }
        save(log, forKey: SharedConstants.activityLogKey)
        logger.notice("[Storage] logActivity: \(entry.method, privacy: .public) status=\(entry.status, privacy: .public) count \(before)→\(log.count)")
    }

    static func getActivityLog() -> [ActivityEntry] {
        let log: [ActivityEntry] = load(forKey: SharedConstants.activityLogKey) ?? []
        logger.notice("[Storage] getActivityLog: \(log.count) entries")
        return log
    }

    static func clearActivityLog() {
        defaults.removeObject(forKey: SharedConstants.activityLogKey)
    }

    // MARK: - Connected Clients

    static func updateClient(pubkey: String, name: String?) {
        var clients = getConnectedClients()
        let now = Date().timeIntervalSince1970
        if let idx = clients.firstIndex(where: { $0.pubkey == pubkey }) {
            clients[idx].lastSeen = now
            clients[idx].requestCount += 1
            if let name, !name.isEmpty { clients[idx].name = name }
        } else {
            clients.append(ConnectedClient(
                pubkey: pubkey,
                name: name,
                firstSeen: now,
                lastSeen: now,
                requestCount: 1
            ))
        }
        save(clients, forKey: SharedConstants.connectedClientsKey)
        logger.notice("[Storage] updateClient: \(pubkey.prefix(8), privacy: .public) total=\(clients.count)")
    }

    static func renameClient(pubkey: String, name: String?) {
        var clients = getConnectedClients()
        if let idx = clients.firstIndex(where: { $0.pubkey == pubkey }) {
            clients[idx].name = name
            save(clients, forKey: SharedConstants.connectedClientsKey)
        }
    }

    static func getConnectedClients() -> [ConnectedClient] {
        load(forKey: SharedConstants.connectedClientsKey) ?? []
    }

    // MARK: - Pending Requests

    static func queuePendingRequest(_ request: PendingRequest) {
        var pending = getPendingRequests()
        pending.append(request)
        if pending.count > 20 { pending = Array(pending.suffix(20)) }
        save(pending, forKey: SharedConstants.pendingRequestsKey)
    }

    static func getPendingRequests() -> [PendingRequest] {
        load(forKey: SharedConstants.pendingRequestsKey) ?? []
    }

    static func removePendingRequest(id: String) {
        var pending = getPendingRequests()
        pending.removeAll { $0.id == id }
        save(pending, forKey: SharedConstants.pendingRequestsKey)
    }

    static func clearPendingRequests() {
        defaults.removeObject(forKey: SharedConstants.pendingRequestsKey)
    }

    // MARK: - Protected Kinds (Always Ask)

    static func getProtectedKinds() -> Set<Int> {
        guard let arr = defaults.array(forKey: SharedConstants.blockedKindsKey) as? [Int] else {
            return [0, 3, 5]
        }
        return Set(arr)
    }

    static func setProtectedKinds(_ kinds: Set<Int>) {
        defaults.set(Array(kinds), forKey: SharedConstants.blockedKindsKey)
    }

    // MARK: - Auto-Sign

    static func isAutoSignEnabled() -> Bool {
        guard defaults.object(forKey: SharedConstants.autoSignKey) != nil else { return true }
        return defaults.bool(forKey: SharedConstants.autoSignKey)
    }

    static func setAutoSign(_ enabled: Bool) {
        defaults.set(enabled, forKey: SharedConstants.autoSignKey)
    }

    // MARK: - Bunker Secret & Paired Clients

    static func getBunkerSecret() -> String {
        if let existing = defaults.string(forKey: SharedConstants.bunkerSecretKey), !existing.isEmpty {
            return existing
        }
        let secret = generateRandomHex(16)
        defaults.set(secret, forKey: SharedConstants.bunkerSecretKey)
        return secret
    }

    static func rotateBunkerSecret() -> String {
        let secret = generateRandomHex(16)
        defaults.set(secret, forKey: SharedConstants.bunkerSecretKey)
        return secret
    }

    static func isClientPaired(_ pubkey: String) -> Bool {
        getPairedClients().contains(pubkey)
    }

    static func pairClient(_ pubkey: String) {
        var paired = getPairedClients()
        paired.insert(pubkey)
        defaults.set(Array(paired), forKey: SharedConstants.pairedClientsKey)
        logger.notice("[Storage] pairClient: \(pubkey.prefix(8), privacy: .public) total=\(paired.count)")
    }

    static func getPairedClients() -> Set<String> {
        Set(defaults.stringArray(forKey: SharedConstants.pairedClientsKey) ?? [])
    }

    static func unpairClient(_ pubkey: String) {
        var paired = getPairedClients()
        paired.remove(pubkey)
        defaults.set(Array(paired), forKey: SharedConstants.pairedClientsKey)
    }

    static func unpairAllClients() {
        defaults.removeObject(forKey: SharedConstants.pairedClientsKey)
    }

    private static func generateRandomHex(_ byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Helpers

    private static func save<T: Encodable>(_ value: T, forKey key: String) {
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: key)
            logger.notice("[Storage] save OK: \(key, privacy: .public) (\(data.count) bytes)")
        } catch {
            logger.error("[Storage] save FAILED: \(key, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load<T: Decodable>(forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else {
            logger.notice("[Storage] load: \(key, privacy: .public) — no data")
            return nil
        }
        do {
            let value = try JSONDecoder().decode(T.self, from: data)
            return value
        } catch {
            logger.error("[Storage] load FAILED: \(key, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
