import Foundation

/// Pure parallel-fanout helpers for multi-relay operations during the nostrconnect handshake.
///
/// All three methods are best-effort: failures are silently dropped so one unreachable
/// relay never blocks the others. Callers that need per-relay status reporting should
/// extend this namespace (see BACKLOG: "Better error-message detail in nostrconnect Activity log").
enum RelayUtils {

    /// Connect to multiple relays in parallel, best-effort.
    /// Returns only the relays that connected successfully within the timeout.
    /// Failures are silently dropped so one unreachable relay never blocks the others.
    static func connectToRelays(urls: [String], timeout: TimeInterval) async -> [LightRelay] {
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
    static func publishEventToRelays(_ relays: [LightRelay], event: [String: Any]) async -> Int {
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
    static func fetchEventsFromRelays(
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
}
