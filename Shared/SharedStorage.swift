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

    static func updateClient(pubkey: String, name: String?, signer signerPubkeyHex: String) {
        var clients = getConnectedClients()
        let now = Date().timeIntervalSince1970
        // Match on composite (signer, client) — same client paired with
        // multiple accounts produces distinct rows.
        if let idx = clients.firstIndex(where: {
            $0.signerPubkeyHex == signerPubkeyHex && $0.pubkey == pubkey
        }) {
            clients[idx].lastSeen = now
            clients[idx].requestCount += 1
            if let name, !name.isEmpty { clients[idx].name = name }
        } else {
            clients.append(ConnectedClient(
                pubkey: pubkey,
                name: name,
                firstSeen: now,
                lastSeen: now,
                requestCount: 1,
                signerPubkeyHex: signerPubkeyHex
            ))
        }
        save(clients, forKey: SharedConstants.connectedClientsKey)
        logger.notice("[Storage] updateClient: \(pubkey.prefix(8), privacy: .public) signer=\(signerPubkeyHex.prefix(8), privacy: .public) total=\(clients.count)")
    }

    static func renameClient(pubkey: String, name: String?) {
        var clients = getConnectedClients()
        if let idx = clients.firstIndex(where: { $0.pubkey == pubkey }) {
            clients[idx].name = name
            save(clients, forKey: SharedConstants.connectedClientsKey)
        }
    }

    /// Persist the client's URI relay set locally. Mirrors the `/pair-client`
    /// payload that already gets sent to the proxy. Used by Layer 1's
    /// foreground subscription to build its target relay set.
    /// (Pre-L1 the field existed in `ConnectedClient` but was never
    /// populated — fixed here.)
    static func setClientRelayUrls(pubkey: String, relayUrls: [String], signer signerPubkeyHex: String) {
        var clients = getConnectedClients()
        let cleaned = relayUrls.filter { !$0.isEmpty }
        // Match on composite (signer, client) — see updateClient rationale.
        if let idx = clients.firstIndex(where: {
            $0.signerPubkeyHex == signerPubkeyHex && $0.pubkey == pubkey
        }) {
            clients[idx].relayUrls = cleaned
            save(clients, forKey: SharedConstants.connectedClientsKey)
            logger.notice("[Storage] setClientRelayUrls: \(pubkey.prefix(8), privacy: .public) signer=\(signerPubkeyHex.prefix(8), privacy: .public) count=\(cleaned.count)")
        } else {
            // Client not yet known — create the entry so the relays are persisted.
            // updateClient will be called separately when the first request comes in.
            let now = Date().timeIntervalSince1970
            clients.append(ConnectedClient(
                pubkey: pubkey,
                name: nil,
                firstSeen: now,
                lastSeen: now,
                requestCount: 0,
                relayUrls: cleaned,
                signerPubkeyHex: signerPubkeyHex
            ))
            save(clients, forKey: SharedConstants.connectedClientsKey)
            logger.notice("[Storage] setClientRelayUrls (new client): \(pubkey.prefix(8), privacy: .public) signer=\(signerPubkeyHex.prefix(8), privacy: .public) count=\(cleaned.count)")
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
        postPendingRequestsUpdated()
    }

    static func getPendingRequests() -> [PendingRequest] {
        load(forKey: SharedConstants.pendingRequestsKey) ?? []
    }

    static func removePendingRequest(id: String) {
        var pending = getPendingRequests()
        pending.removeAll { $0.id == id }
        save(pending, forKey: SharedConstants.pendingRequestsKey)
        postPendingRequestsUpdated()
    }

    static func clearPendingRequests() {
        defaults.removeObject(forKey: SharedConstants.pendingRequestsKey)
        postPendingRequestsUpdated()
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

    // MARK: - Multi-account filtered readers
    //
    // Added 2026-05-01 (feat/multi-account, Task 4). Pure filters over the
    // existing flat-array storage — matches noauth's "filter by foreign key"
    // pattern. Unfiltered readers (above) are intentionally kept; the merged
    // PendingApprovalsView (Phase 2) uses the unfiltered `getPendingRequests()`
    // and groups by signer at render time. Other unfiltered surfaces should
    // migrate to the `(for:)` variants in Task 7.

    static func getActivityLog(for signerPubkeyHex: String) -> [ActivityEntry] {
        getActivityLog().filter { $0.signerPubkeyHex == signerPubkeyHex }
    }

    static func getPendingRequests(for signerPubkeyHex: String) -> [PendingRequest] {
        getPendingRequests().filter { $0.signerPubkeyHex == signerPubkeyHex }
    }

    static func getConnectedClients(for signerPubkeyHex: String) -> [ConnectedClient] {
        getConnectedClients().filter { $0.signerPubkeyHex == signerPubkeyHex }
    }

    /// Note: argument label `forSigner:` (not `for:`) to disambiguate from
    /// the legacy single-arg `getClientPermissions(for: pubkey)` (which
    /// matches by client pubkey). Both `String` → Swift can't pick the
    /// right overload from the label `for:` alone. Kept this way until
    /// the legacy variant is deleted in a future task.
    static func getClientPermissions(forSigner signerPubkeyHex: String) -> [ClientPermissions] {
        getClientPermissions().filter { $0.signerPubkeyHex == signerPubkeyHex }
    }

    static func getClientPermissions(signer signerPubkeyHex: String, client clientPubkey: String) -> ClientPermissions? {
        getClientPermissions().first {
            $0.signerPubkeyHex == signerPubkeyHex && $0.pubkey == clientPubkey
        }
    }

    static func getPendingPairOps(for signerPubkeyHex: String) -> [PairOp] {
        getPendingPairOps().filter { $0.signerPubkeyHex == signerPubkeyHex }
    }

    // MARK: - Bunker Secrets (per-signer)
    //
    // Each account has its own bunker secret rotated independently. Stored
    // as `[signerPubkeyHex: secretHex]` under `bunkerSecretsKey`. Replaces
    // the legacy global `bunkerSecretKey` (still readable for one-shot
    // migration via the legacy-seed branch in `getBunkerSecret(for:)`).

    /// Returns the bunker secret for the signer, generating one on first
    /// read. Defense-in-depth migration: if the per-signer dict is empty
    /// AND a legacy global secret exists, the first signer to ask inherits
    /// that secret. Task 8 migration also explicitly migrates the legacy
    /// secret; this branch is the fallback if migration hasn't run yet.
    static func getBunkerSecret(for signerPubkeyHex: String) -> String {
        var dict = bunkerSecretsDict()
        if let existing = dict[signerPubkeyHex], !existing.isEmpty {
            return existing
        }
        if dict.isEmpty,
           let legacy = defaults.string(forKey: SharedConstants.bunkerSecretKey),
           !legacy.isEmpty {
            dict[signerPubkeyHex] = legacy
            saveBunkerSecretsDict(dict)
            return legacy
        }
        let secret = generateRandomHex(16)
        dict[signerPubkeyHex] = secret
        saveBunkerSecretsDict(dict)
        return secret
    }

    @discardableResult
    static func rotateBunkerSecret(for signerPubkeyHex: String) -> String {
        var dict = bunkerSecretsDict()
        let secret = generateRandomHex(16)
        dict[signerPubkeyHex] = secret
        saveBunkerSecretsDict(dict)
        return secret
    }

    private static func bunkerSecretsDict() -> [String: String] {
        load(forKey: SharedConstants.bunkerSecretsKey) ?? [:]
    }

    private static func saveBunkerSecretsDict(_ dict: [String: String]) {
        save(dict, forKey: SharedConstants.bunkerSecretsKey)
    }

    // MARK: - Paired Clients (legacy migration only)
    //
    // The `pairedClientsKey` UserDefaults set was the pre-V2 way to track
    // paired clients. Superseded by ClientPermissions (V2). The only
    // remaining caller is `migrateIfNeeded()` below, which reads the
    // legacy set on first launch after the V2 update and converts each
    // entry to a ClientPermissions row. Privatized in Task 4 — no
    // external surface.
    private static func getPairedClients() -> Set<String> {
        Set(defaults.stringArray(forKey: SharedConstants.pairedClientsKey) ?? [])
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

    /// Returns the FIRST ClientPermissions row matching the client pubkey,
    /// regardless of which signer it's paired with. Multi-account caveat:
    /// in true multi-account scenarios, the same client pubkey may have
    /// rows under multiple signers, and this returns whichever appears
    /// first in storage — which is non-deterministic. Use
    /// `getClientPermissions(signer:client:)` (Task 4) when the signer
    /// scope is known.
    ///
    /// Phase 1 callers (NSE, banner, view rows) still use this variant
    /// because the migrated single-account user has only one row per
    /// client pubkey, so the result is unambiguous. Task 7 + follow-up
    /// passes update these callers to the scoped variant.
    static func getClientPermissions(for pubkey: String) -> ClientPermissions? {
        getClientPermissions().first { $0.pubkey == pubkey }
    }

    /// Save a permissions row, matching for replacement on the composite
    /// `(signerPubkeyHex, pubkey)` key. Legacy rows with empty
    /// `signerPubkeyHex` are matched the same way (composite still works
    /// — empty signer matches empty signer). Without composite matching,
    /// the same client paired with two signers would clobber across.
    static func saveClientPermissions(_ permissions: ClientPermissions) {
        var all = getClientPermissions()
        if let idx = all.firstIndex(where: {
            $0.signerPubkeyHex == permissions.signerPubkeyHex && $0.pubkey == permissions.pubkey
        }) {
            all[idx] = permissions
        } else {
            all.append(permissions)
        }
        save(all, forKey: SharedConstants.clientPermissionsKey)
        logger.notice("[Storage] saveClientPermissions: signer=\(permissions.signerPubkeyHex.prefix(8), privacy: .public) client=\(permissions.pubkey.prefix(8), privacy: .public) trust=\(permissions.trustLevel.rawValue, privacy: .public)")
    }

    /// Scoped variant — removes ONE specific (signer, client) pair without
    /// touching other signers' rows for the same client. Replaces the
    /// pre-Task-4 single-arg `removeClientPermissions(for: pubkey)` which
    /// would clobber across signers.
    static func removeClientPermissions(signer signerPubkeyHex: String, client clientPubkey: String) {
        var all = getClientPermissions()
        all.removeAll {
            $0.signerPubkeyHex == signerPubkeyHex && $0.pubkey == clientPubkey
        }
        save(all, forKey: SharedConstants.clientPermissionsKey)
        // Also remove the corresponding ConnectedClient row (legacy parity
        // with pre-Task-4 `unpairClient(_:)`, scoped here to the matching
        // signer).
        var clients = getConnectedClients()
        clients.removeAll {
            $0.signerPubkeyHex == signerPubkeyHex && $0.pubkey == clientPubkey
        }
        save(clients, forKey: SharedConstants.connectedClientsKey)
        logger.notice("[Storage] removeClientPermissions: signer=\(signerPubkeyHex.prefix(8), privacy: .public) client=\(clientPubkey.prefix(8), privacy: .public)")
    }

    /// Clear all of a single signer's ClientPermissions and ConnectedClient
    /// rows. Replaces the pre-Task-4 global `unpairAllClients()` which
    /// nuked the legacy `pairedClientsKey` set across all signers — the
    /// multi-account `deleteAccount` (Task 5) MUST NOT call the global
    /// variant; it calls this scoped form instead.
    static func unpairAllClients(for signerPubkeyHex: String) {
        var perms = getClientPermissions()
        let beforeP = perms.count
        perms.removeAll { $0.signerPubkeyHex == signerPubkeyHex }
        save(perms, forKey: SharedConstants.clientPermissionsKey)

        var clients = getConnectedClients()
        let beforeC = clients.count
        clients.removeAll { $0.signerPubkeyHex == signerPubkeyHex }
        save(clients, forKey: SharedConstants.connectedClientsKey)

        logger.notice("[Storage] unpairAllClients(for: \(signerPubkeyHex.prefix(8), privacy: .public)) perms=\(beforeP)→\(perms.count) clients=\(beforeC)→\(clients.count)")
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

    /// Scoped variant — update lastSeen and requestCount for the
    /// (signer, client) pair after a successful request. Replaces the
    /// pre-Task-4 `touchClient(pubkey:)` which matched by client only and
    /// could touch the wrong signer's row in multi-account scenarios.
    /// Caller (LightSigner.swift:564) derives the signer from
    /// `LightEvent.pubkeyHex(from: privateKey)` once per request.
    static func touchClient(pubkey: String, signer signerPubkeyHex: String) {
        guard var perms = getClientPermissions(signer: signerPubkeyHex, client: pubkey) else { return }
        perms.lastSeen = Date().timeIntervalSince1970
        perms.requestCount += 1
        saveClientPermissions(perms)
    }

    // MARK: - Last contact-list snapshot (kind:3 diff, per-signer)
    //
    // CRITICAL CORRECTNESS FIX from PR #19 in multi-account context: a
    // single global key would corrupt across accounts (account A's
    // snapshot diff'd against account B's new kind:3 → wildly wrong
    // follow summaries). Stored as
    // `[signerPubkeyHex: sortedPubkeys]` under `lastContactSetsKey`.

    /// The most-recently-signed kind:3 contact-list pubkey set for this
    /// signer, or nil if no kind:3 has been signed yet for this account.
    /// Used by `ActivitySummary` to compute add/remove diffs.
    static func getLastContactSet(for signerPubkeyHex: String) -> Set<String>? {
        let dict = lastContactSetsDict()
        guard let arr = dict[signerPubkeyHex] else { return nil }
        return Set(arr)
    }

    /// Replace this signer's snapshot with the given pubkey set. Stored
    /// as a sorted array per-signer for stable serialization. Pass `nil`
    /// to clear that signer's entry (other signers' entries unaffected).
    static func saveLastContactSet(_ set: Set<String>?, for signerPubkeyHex: String) {
        var dict = lastContactSetsDict()
        if let set {
            dict[signerPubkeyHex] = Array(set).sorted()
        } else {
            dict.removeValue(forKey: signerPubkeyHex)
        }
        saveLastContactSetsDict(dict)
    }

    private static func lastContactSetsDict() -> [String: [String]] {
        load(forKey: SharedConstants.lastContactSetsKey) ?? [:]
    }

    private static func saveLastContactSetsDict(_ dict: [String: [String]]) {
        save(dict, forKey: SharedConstants.lastContactSetsKey)
    }

    // MARK: - Per-signer register timestamps
    //
    // Each account registers with the proxy independently. Throttle +
    // cooldown for `AppState.ensureRegisteredFresh` are tracked
    // per-signer here. Stored as
    // `[signerPubkeyHex: ["succeeded": ts, "failed": ts]]` under
    // `lastRegisterTimesKey`. Replaces the legacy global
    // `lastRegisterSucceededAtKey` / `lastRegisterFailedAtKey`.

    static func getLastRegisterSucceededAt(for signerPubkeyHex: String) -> Double? {
        registerTimesDict()[signerPubkeyHex]?["succeeded"]
    }

    static func setLastRegisterSucceededAt(_ ts: Double, for signerPubkeyHex: String) {
        var dict = registerTimesDict()
        var inner = dict[signerPubkeyHex] ?? [:]
        inner["succeeded"] = ts
        dict[signerPubkeyHex] = inner
        saveRegisterTimesDict(dict)
    }

    static func getLastRegisterFailedAt(for signerPubkeyHex: String) -> Double? {
        registerTimesDict()[signerPubkeyHex]?["failed"]
    }

    static func setLastRegisterFailedAt(_ ts: Double, for signerPubkeyHex: String) {
        var dict = registerTimesDict()
        var inner = dict[signerPubkeyHex] ?? [:]
        inner["failed"] = ts
        dict[signerPubkeyHex] = inner
        saveRegisterTimesDict(dict)
    }

    private static func registerTimesDict() -> [String: [String: Double]] {
        load(forKey: SharedConstants.lastRegisterTimesKey) ?? [:]
    }

    private static func saveRegisterTimesDict(_ dict: [String: [String: Double]]) {
        save(dict, forKey: SharedConstants.lastRegisterTimesKey)
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

    // MARK: - Pending-requests change broadcast

    /// Posts an in-process NotificationCenter event so the main app's UI can
    /// refresh without waiting for scenePhase or onAppear. Posted from
    /// queue/remove/clear so any code path that mutates the pending-requests
    /// list triggers a UI update.
    ///
    /// In-process only: NSE and the main app are separate processes, so this
    /// notification does NOT cross between them. The main app picks up
    /// NSE-side writes via the MainTabView scenePhase observer when the app
    /// foregrounds (UserDefaults state is persistent across the process
    /// boundary; only the wake-up signal is missing). Within the main app
    /// process (L1 foreground sub, ApprovalSheet approve/deny, AppState),
    /// this notification gives the UI an immediate refresh signal.
    private static func postPendingRequestsUpdated() {
        NotificationCenter.default.post(name: .pendingRequestsUpdated, object: nil)
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

// Defined in Shared/ so both NSE and the main app reference the same name.
// Currently only posted in-process (see SharedStorage.postPendingRequestsUpdated).
extension Notification.Name {
    static let pendingRequestsUpdated = Notification.Name("pendingRequestsUpdated")
}
