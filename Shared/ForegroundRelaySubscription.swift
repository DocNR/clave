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

    // MARK: - Internals (filled in subsequent tasks)

    private var dispatcherTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

    func start() {
        guard state == .idle || state == .error else { return }
        state = .starting
        statusMessage = "Connecting…"
        // TODO(Task 5): spawn dispatcher Task that runs withTaskGroup
        // over the relay set and processes incoming kind:24133 events.
        logger.notice("[fg-sub] start() called (skeleton — no-op until Task 5)")
    }

    func stop() {
        guard state != .idle else { return }
        state = .stopping
        dispatcherTask?.cancel()
        dispatcherTask = nil
        state = .idle
        statusMessage = "Idle"
        logger.notice("[fg-sub] stop() called")
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
}
