import Foundation
import Observation
import os.log

/// Foreground RPC accelerator. While Clave's main app is in the foreground,
/// holds open WebSocket subscriptions to the user's relays and processes
/// incoming kind:24133 NIP-46 RPCs inline via `LightSigner.handleRequest`,
/// bypassing APNs+NSE for ~10× per-RPC speedup.
///
/// **`@MainActor` is the first introduction in Clave.** A grep across `Shared/`
/// and `Clave/` confirms zero existing uses. Chosen because this class owns
/// `@Observable` properties driving SwiftUI bindings (status indicators,
/// progress UI in Layer 2); MainActor isolation simplifies those bindings
/// without manual main-thread hops. The cost is contained — callers from
/// non-isolated contexts (e.g. `AppState`) hop in via `Task { @MainActor in ... }`.
///
/// See spec: `~/hq/clave/specs/2026-04-26-foreground-bulk-decrypt-design.md`
/// (Layer 1 section). Empirical justification:
/// `~/hq/clave/research/nip17-bulk-decrypt/FINDINGS.md`.
///
/// Layer 2 (bulk decrypt session UX, conversation-key cache, auth_url
/// heuristic) builds on top of this class without modifying it. L1 is shipped
/// standalone first so users get the "Clave is snappier when open" benefit
/// before any L2 UX exists.

private let logger = Logger(subsystem: "dev.nostr.clave", category: "fg-sub")

@Observable
@MainActor
final class ForegroundRelaySubscription {
    static let shared = ForegroundRelaySubscription()

    // MARK: - State

    enum State: String {
        case idle
        case starting
        case listening
        case reconnecting
        case stopping
        case error
    }

    private(set) var state: State = .idle
    private(set) var statusMessage: String = "Idle"
    private(set) var eventsReceived: Int = 0
    private(set) var eventsProcessed: Int = 0
    private(set) var eventsFailed: Int = 0
    private(set) var lastError: String?

    /// Ring buffer of last 1024 latencies (ms). Layer 2's progress UI reads this.
    private(set) var recentLatenciesMs: [Double] = []
    private static let latencyRingCap = 1024

    // MARK: - Internals

    private var dispatcherTask: Task<Void, Never>?

    /// Default concurrency cap for per-event dispatch. Empirical sweet spot
    /// from FINDINGS.md (S1k-c5 vs S1k-c20 showed no throughput gain past
    /// concurrency=5, just queueing latency). Layer 2 may tune.
    static let defaultConcurrency = 5

    /// Per-event budget. Hard upper bound on a single LightSigner.handleRequest
    /// invocation; if the publish path hangs, we cancel and free the slot.
    static let perEventBudgetSeconds: UInt64 = 30

    /// Concurrency cap. Backpressure point that prevents the receive loop
    /// from outrunning the dispatcher under bursts.
    private let dispatchSemaphore = AsyncSemaphore(Self.defaultConcurrency)

    private init() {}

    // MARK: - Public API

    func start() {
        guard state == .idle || state == .error else {
            logger.notice("[fg-sub] start() called in state \(self.state.rawValue, privacy: .public) — no-op")
            return
        }

        let userPubkey = SharedConstants.sharedDefaults.string(forKey: SharedConstants.signerPubkeyHexKey) ?? ""
        if userPubkey.isEmpty {
            lastError = "No signer key configured"
            state = .error
            statusMessage = "Error"
            return
        }

        let relays = relaySet()
        if relays.isEmpty {
            lastError = "No relays configured (no paired clients)"
            state = .error
            statusMessage = "Error"
            return
        }

        state = .starting
        statusMessage = "Connecting…"
        eventsReceived = 0
        eventsProcessed = 0
        eventsFailed = 0
        lastError = nil

        logger.notice("[fg-sub] start: relays=\(relays.count) user=\(userPubkey.prefix(8), privacy: .public)…")

        dispatcherTask = Task { [self] in
            await self.runDispatcher(relays: relays, userPubkey: userPubkey)
        }
    }

    func stop() {
        guard state != .idle else { return }
        logger.notice("[fg-sub] stop() called from state=\(self.state.rawValue, privacy: .public)")
        state = .stopping
        dispatcherTask?.cancel()
        dispatcherTask = nil
        // dispatcher exits inside runDispatcher() which transitions back to .idle
    }

    func resetCounters() {
        eventsReceived = 0
        eventsProcessed = 0
        eventsFailed = 0
        recentLatenciesMs.removeAll(keepingCapacity: true)
        lastError = nil
    }

    // MARK: - Latency tracking

    fileprivate func recordLatency(_ ms: Double) {
        recentLatenciesMs.append(ms)
        if recentLatenciesMs.count > Self.latencyRingCap {
            recentLatenciesMs.removeFirst(recentLatenciesMs.count - Self.latencyRingCap)
        }
    }

    // MARK: - Relay set

    /// Returns the union of relayUrls across paired clients, plus the primary
    /// bunker relay as a guaranteed fallback. De-duplicated.
    private func relaySet() -> [String] {
        var set = Set<String>()
        set.insert(SharedConstants.relayURL)
        for client in SharedStorage.getConnectedClients() {
            for url in client.relayUrls where !url.isEmpty {
                set.insert(url)
            }
        }
        return Array(set)
    }

    // MARK: - Dispatcher

    private func runDispatcher(relays: [String], userPubkey: String) async {
        // One long-lived TaskGroup per dispatcher run. Each child task is a
        // per-relay loop that connects, REQs, processes events, reconnects on
        // failure. The group ends when the dispatcherTask is cancelled (stop()).
        await withTaskGroup(of: Void.self) { group in
            for relay in relays {
                group.addTask { [self] in
                    await self.runRelayLoop(relayURL: relay, userPubkey: userPubkey)
                }
            }
            // Group blocks until all child tasks finish; they only finish when
            // Task.isCancelled becomes true (via stop()).
        }

        // Dispatcher exit — return to idle. Triggered by stop() (or unrecoverable error).
        self.state = .idle
        self.statusMessage = "Idle"
        logger.notice("[fg-sub] dispatcher exited; state=idle")
    }

    private func runRelayLoop(relayURL: String, userPubkey: String) async {
        let conn = RelayConnection(url: relayURL)
        var backoffSeconds: UInt64 = 1
        let maxBackoff: UInt64 = 16

        while !Task.isCancelled {
            do {
                try await conn.connect()
                backoffSeconds = 1  // reset on successful connect

                let foregroundStart = Date().timeIntervalSince1970
                // 60s lookback so events published just before foregrounding
                // (e.g., the auth_url-triggered burst) are caught.
                let since = foregroundStart - 60
                let subId = "fg-\(UUID().uuidString.prefix(8))".lowercased()
                let filter: [String: Any] = [
                    "kinds": [24133],
                    "#p": [userPubkey],
                    "since": Int(since)
                ]
                let reqArray: [Any] = ["REQ", subId, filter]
                let reqData = try JSONSerialization.data(withJSONObject: reqArray)
                let reqString = String(data: reqData, encoding: .utf8)!
                try await conn.send(.string(reqString))

                self.state = .listening
                self.statusMessage = "Listening on \(relayURL)"
                logger.notice("[fg-sub] subscribed sub=\(subId, privacy: .public) relay=\(relayURL, privacy: .public)")

                // Concurrent: receive loop + heartbeat. Whichever throws first
                // bubbles up and triggers a reconnect.
                try await withThrowingTaskGroup(of: Void.self) { inner in
                    inner.addTask { [self] in
                        try await self.receiveLoop(conn: conn, subId: subId, userPubkey: userPubkey)
                    }
                    inner.addTask { [self] in
                        try await self.heartbeatLoop(conn: conn)
                    }
                    _ = try await inner.next()
                    inner.cancelAll()
                }
            } catch {
                if Task.isCancelled { break }
                let msg = "relay=\(relayURL) error: \(error.localizedDescription)"
                logger.error("[fg-sub] \(msg, privacy: .public)")
                self.lastError = msg
                self.state = .reconnecting
                self.statusMessage = "Reconnecting in \(backoffSeconds)s…"

                try? await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)
                backoffSeconds = min(backoffSeconds * 2, maxBackoff)
                await conn.disconnect()
            }
        }

        await conn.disconnect()
        logger.notice("[fg-sub] runRelayLoop(\(relayURL, privacy: .public)) exited")
    }

    // MARK: - Receive loop (event dispatch wired in Task 6)

    private func receiveLoop(
        conn: RelayConnection,
        subId: String,
        userPubkey: String
    ) async throws {
        while !Task.isCancelled {
            let message = try await conn.receive()

            guard case .string(let text) = message,
                  let data = text.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let type = array.first as? String else { continue }

            switch type {
            case "EVENT":
                guard array.count >= 3,
                      let eventSubId = array[1] as? String, eventSubId == subId,
                      let eventDict = array[2] as? [String: Any] else { continue }

                self.eventsReceived += 1

                // Backpressure: receive loop awaits a permit before spawning the
                // per-event task. Five permits is the FINDINGS.md sweet spot.
                await dispatchSemaphore.acquire()
                Task { [self] in
                    defer { Task { await self.dispatchSemaphore.release() } }
                    await self.processEvent(eventDict, relayURL: conn.url)
                }

            case "EOSE":
                logger.notice("[fg-sub] EOSE — staying subscribed")
            case "NOTICE":
                let notice = (array.count >= 2 ? array[1] as? String : nil) ?? ""
                logger.notice("[fg-sub] NOTICE: \(notice, privacy: .public)")
            case "CLOSED":
                let reason = (array.count >= 3 ? array[2] as? String : nil) ?? "(no reason)"
                throw RelayConnectionError.subscriptionClosed(reason)
            default:
                continue
            }
        }
    }

    private func heartbeatLoop(conn: RelayConnection) async throws {
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 30_000_000_000)  // 30s
            try await conn.ping()
        }
    }

    // MARK: - Per-event dispatch

    /// Dispatches a single kind:24133 event through `LightSigner.handleRequest`
    /// with a per-event 30s budget. Updates counters + latency ring buffer.
    /// Runs off the MainActor inside a Task spawned by the receive loop.
    private nonisolated func processEvent(
        _ eventDict: [String: Any],
        relayURL: String
    ) async {
        guard let nsec = SharedKeychain.loadNsec(),
              let privateKey = try? Bech32.decodeNsec(nsec) else {
            await MainActor.run {
                self.lastError = "Failed to load signer key"
                self.eventsFailed += 1
            }
            return
        }

        let started = Date()

        // 30s budget enforced via withTaskGroup race: the work task vs.
        // a sleep-then-cancel watchdog. First to complete wins; the other
        // is cancelled by the group.
        let result: LightSigner.RequestResult? = await withTaskGroup(
            of: LightSigner.RequestResult?.self
        ) { group in
            group.addTask {
                do {
                    return try await LightSigner.handleRequest(
                        privateKey: privateKey,
                        requestEvent: eventDict,
                        skipProtection: false,
                        responseRelayUrl: relayURL
                    )
                } catch {
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: Self.perEventBudgetSeconds * 1_000_000_000)
                return nil  // timeout sentinel
            }

            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }

        let elapsedMs = Date().timeIntervalSince(started) * 1000

        await MainActor.run {
            // "signed" — completed normally. "skipped-duplicate" — already
            // handled by NSE or another path. Both count as processed.
            // Other statuses (error/blocked/pending) count as failed for
            // L1 telemetry; protected-kind queue prompts go via the
            // existing path and don't appear here.
            if let result = result, result.status == "signed" || result.status == "skipped-duplicate" {
                self.eventsProcessed += 1
            } else {
                self.eventsFailed += 1
            }
            self.recordLatency(elapsedMs)
        }
    }
}

// MARK: - Async semaphore for receive-loop backpressure

/// Simple actor-isolated counting semaphore. `acquire()` waits if the permit
/// count is zero; `release()` resumes the next waiter or restores a permit.
private actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ initial: Int) { self.permits = initial }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            permits += 1
        }
    }
}

// MARK: - Per-relay WebSocket connection (actor-isolated)

/// Wraps a single `URLSessionWebSocketTask` with actor-isolated send/receive/ping.
/// Lifetime is one connect/disconnect cycle; reconnect creates a fresh socket
/// inside the same actor by calling connect() again.
private actor RelayConnection {
    let url: String
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?

    init(url: String) { self.url = url }

    func connect() async throws {
        guard let urlObj = URL(string: url) else {
            throw RelayConnectionError.invalidURL(url)
        }
        // Fresh URLSession per connect so we don't reuse a poisoned one.
        let session = URLSession(configuration: .default)
        self.session = session
        let ws = session.webSocketTask(with: urlObj)
        ws.resume()
        self.task = ws

        // Verify the connection is up via a ping. If the server is unreachable
        // or the URL is bad, sendPing's callback fires with an error.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // Guard against double-resume (URLSessionWebSocketTask sometimes
            // calls callbacks multiple times on cancel-after-pong).
            let lock = NSLock()
            var fired = false
            ws.sendPing { error in
                lock.lock(); defer { lock.unlock() }
                if fired { return }
                fired = true
                if let error = error { cont.resume(throwing: error) }
                else { cont.resume() }
            }
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard let task = task else { throw RelayConnectionError.notConnected }
        try await task.send(message)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        guard let task = task else { throw RelayConnectionError.notConnected }
        return try await task.receive()
    }

    func ping() async throws {
        guard let task = task else { throw RelayConnectionError.notConnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let lock = NSLock()
            var fired = false
            task.sendPing { error in
                lock.lock(); defer { lock.unlock() }
                if fired { return }
                fired = true
                if let error = error { cont.resume(throwing: error) }
                else { cont.resume() }
            }
        }
    }

    func disconnect() async {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }
}

private enum RelayConnectionError: LocalizedError {
    case invalidURL(String)
    case notConnected
    case subscriptionClosed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let u): return "Invalid relay URL: \(u)"
        case .notConnected: return "Not connected to relay"
        case .subscriptionClosed(let r): return "Relay closed subscription: \(r)"
        }
    }
}
