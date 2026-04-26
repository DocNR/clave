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

    // MARK: - Pending Pair Ops (HTTP failure retry queue)

    /// Queue an operation to be retried on next drain. FIFO, cap 10 — drops
    /// oldest on overflow.
    static func enqueuePendingPairOp(_ op: PairOp) {
        var queue = getPendingPairOps()
        queue.append(op)
        if queue.count > 10 { queue = Array(queue.suffix(10)) }
        save(queue, forKey: SharedConstants.pendingPairOpsKey)
        logger.notice("[Storage] enqueuePendingPairOp: \(op.kind.rawValue, privacy: .public) client=\(op.clientPubkey.prefix(8), privacy: .public) count=\(queue.count)")
    }

    static func getPendingPairOps() -> [PairOp] {
        load(forKey: SharedConstants.pendingPairOpsKey) ?? []
    }

    static func removePendingPairOp(id: String) {
        var queue = getPendingPairOps()
        queue.removeAll { $0.id == id }
        save(queue, forKey: SharedConstants.pendingPairOpsKey)
    }

    static func bumpPendingPairOpFailCount(id: String) {
        var queue = getPendingPairOps()
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[idx].failCount += 1
        save(queue, forKey: SharedConstants.pendingPairOpsKey)
    }

    static func clearPendingPairOps() {
        defaults.removeObject(forKey: SharedConstants.pendingPairOpsKey)
    }

    // MARK: - Protected Kinds (Always Ask)

    static func getProtectedKinds() -> Set<Int> {
        guard let arr = defaults.array(forKey: SharedConstants.blockedKindsKey) as? [Int] else {
            return [0, 3, 5, 10002, 30078]
        }
        return Set(arr)
    }

    static func setProtectedKinds(_ kinds: Set<Int>) {
        defaults.set(Array(kinds), forKey: SharedConstants.blockedKindsKey)
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
        var clients = getConnectedClients()
        clients.removeAll { $0.pubkey == pubkey }
        save(clients, forKey: SharedConstants.connectedClientsKey)
    }

    static func unpairAllClients() {
        defaults.removeObject(forKey: SharedConstants.pairedClientsKey)
    }

    private static func generateRandomHex(_ byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Client Permissions

    static func getClientPermissions() -> [ClientPermissions] {
        load(forKey: SharedConstants.clientPermissionsKey) ?? []
    }

    static func getClientPermissions(for pubkey: String) -> ClientPermissions? {
        getClientPermissions().first { $0.pubkey == pubkey }
    }

    static func saveClientPermissions(_ permissions: ClientPermissions) {
        var all = getClientPermissions()
        if let idx = all.firstIndex(where: { $0.pubkey == permissions.pubkey }) {
            all[idx] = permissions
        } else {
            all.append(permissions)
        }
        save(all, forKey: SharedConstants.clientPermissionsKey)
        logger.notice("[Storage] saveClientPermissions: \(permissions.pubkey.prefix(8), privacy: .public) trust=\(permissions.trustLevel.rawValue, privacy: .public)")
    }

    static func removeClientPermissions(for pubkey: String) {
        var all = getClientPermissions()
        all.removeAll { $0.pubkey == pubkey }
        save(all, forKey: SharedConstants.clientPermissionsKey)
        // Also remove from legacy stores
        unpairClient(pubkey)
    }

    /// Migrate legacy paired clients to ClientPermissions (one-time, on first launch after update)
    static func migrateIfNeeded() {
        // Skip if already migrated (clientPermissions key exists with data)
        if defaults.data(forKey: SharedConstants.clientPermissionsKey) != nil {
            return
        }
        let paired = getPairedClients()
        guard !paired.isEmpty else { return }

        let existingClients = getConnectedClients()
        var migrated: [ClientPermissions] = []

        for pubkey in paired {
            let existing = existingClients.first { $0.pubkey == pubkey }
            let permissions = ClientPermissions(
                pubkey: pubkey,
                trustLevel: .medium,
                kindOverrides: [:],
                methodPermissions: ClientPermissions.defaultMethodPermissions,
                name: existing?.name,
                url: nil,
                imageURL: nil,
                connectedAt: existing?.firstSeen ?? Date().timeIntervalSince1970,
                lastSeen: existing?.lastSeen ?? Date().timeIntervalSince1970,
                requestCount: existing?.requestCount ?? 0
            )
            migrated.append(permissions)
        }

        save(migrated, forKey: SharedConstants.clientPermissionsKey)
        logger.notice("[Storage] Migrated \(migrated.count) paired clients to ClientPermissions")
    }

    /// Update lastSeen and requestCount for a client after a successful request
    static func touchClient(pubkey: String) {
        guard var perms = getClientPermissions(for: pubkey) else { return }
        perms.lastSeen = Date().timeIntervalSince1970
        perms.requestCount += 1
        saveClientPermissions(perms)
    }

    // MARK: - Per-event-id dedupe (cross-process via app-group UserDefaults)
    //
    // Used by LightSigner.handleRequest to short-circuit duplicate processing
    // when both NSE and the foreground app's WebSocket sub catch the same event.
    //
    // Lossy semantics across processes are acceptable: occasional double-publish
    // is harmless because NIP-46 clients dedupe responses by `id`. Within one
    // process, the lock ensures atomic check-and-insert.
    //
    // Audit D.1.1: insertion-ordered ring buffer (200 entries) + age bound
    // (60s based on event.created_at). Replaces the prior Set + .suffix(50)
    // logic that was duplicated inline in Clave/ClaveApp.swift and
    // ClaveNSE/NotificationService.swift; those call sites are removed once
    // LightSigner becomes the single dedupe choke point.

    enum ProcessedStatus { case markedNew, alreadyProcessed }

    private static let processedEventIDsCap = 200
    private static let processedEventIDsAgeWindow: Double = 60  // seconds

    #if DEBUG
    nonisolated(unsafe) private static var processedEventIDsKeyOverride: String?
    static func _setProcessedEventIDsKeyForTesting(_ key: String) { processedEventIDsKeyOverride = key }
    static func _resetProcessedEventIDsKeyForTesting() { processedEventIDsKeyOverride = nil }
    #endif

    private static var processedEventIDsKey: String {
        #if DEBUG
        return processedEventIDsKeyOverride ?? "processedEventIDs"
        #else
        return "processedEventIDs"
        #endif
    }

    private static let processedEventIDsLock = NSLock()  // intra-process only

    /// Stored format: array of `"<eventId>:<createdAt>"` strings, insertion order
    /// preserved by Array semantics. Cross-process races may produce duplicate
    /// inserts; NIP-46 client-side id-match handles the resulting double-response.
    static func markEventProcessed(eventId: String, createdAt: Double) -> ProcessedStatus {
        processedEventIDsLock.lock()
        defer { processedEventIDsLock.unlock() }

        let now = Date().timeIntervalSince1970
        var entries = defaults.stringArray(forKey: processedEventIDsKey) ?? []

        // Age-based eviction sweep on every call (cheap — bounded list).
        entries = entries.filter { entry in
            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let ts = Double(parts[1]) else { return false }
            return (now - ts) <= processedEventIDsAgeWindow
        }

        // Check if eventId already present.
        let prefix = "\(eventId):"
        if entries.contains(where: { $0.hasPrefix(prefix) }) {
            // Refresh storage with the post-eviction list (may have changed).
            defaults.set(entries, forKey: processedEventIDsKey)
            return .alreadyProcessed
        }

        // Insert.
        entries.append("\(eventId):\(createdAt)")
        if entries.count > processedEventIDsCap {
            entries.removeFirst(entries.count - processedEventIDsCap)
        }
        defaults.set(entries, forKey: processedEventIDsKey)
        return .markedNew
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
