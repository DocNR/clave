import Foundation
import os.log

private let logger = Logger(subsystem: "dev.nostr.clave", category: "relay")

/// Thread-safe single-fire guard. Used to make `URLSessionWebSocketTask` callbacks
/// that might be invoked more than once (observed on cancel-after-pong races) safe
/// to use with `withCheckedThrowingContinuation`, which crashes on double-resume.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false
    nonisolated init() {}
    func consume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if consumed { return false }
        consumed = true
        return true
    }
}

final class LightRelay: @unchecked Sendable {
    private var webSocket: URLSessionWebSocketTask?
    private let urlString: String
    private let session: URLSession

    nonisolated init(url: String) {
        self.urlString = url
        self.session = URLSession(configuration: .default)
    }

    func connect(timeout: TimeInterval = 5.0) async throws {
        guard let url = URL(string: urlString) else { throw LightRelayError.invalidURL }
        let ws = session.webSocketTask(with: url)
        ws.resume()
        self.webSocket = ws

        // Wait for connection with timeout.
        // The ping continuation does NOT cooperate with Swift cancellation,
        // so on timeout we must cancel the URLSession task to force the ping
        // callback to fire with an error. Otherwise the child task leaks the
        // continuation and the TaskGroup can never return.
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    // URLSessionWebSocketTask.sendPing can invoke its callback more than once
                    // when the task is cancelled shortly after the pong arrives. Guard against
                    // double-resume, which is a fatal error for CheckedContinuation.
                    let fired = ResumeOnce()
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        ws.sendPing { error in
                            guard fired.consume() else { return }
                            if let error = error { cont.resume(throwing: error) }
                            else { cont.resume() }
                        }
                    }
                }
                group.addTask { [weak ws] in
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    ws?.cancel(with: .abnormalClosure, reason: nil)
                    throw LightRelayError.timeout
                }
                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            ws.cancel(with: .abnormalClosure, reason: nil)
            self.webSocket = nil
            throw error
        }
        logger.notice("[LightRelay] Connected to \(self.urlString)")
    }

    /// Receive the next WebSocket message with a hard timeout.
    /// On timeout, the underlying task is cancelled so a silent relay cannot
    /// stall the caller indefinitely (URLSessionWebSocketTask.receive has no
    /// built-in timeout and does not honor Task cancellation on its own).
    private static func receiveWithTimeout(
        ws: URLSessionWebSocketTask,
        timeout: TimeInterval
    ) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask {
                try await ws.receive()
            }
            group.addTask { [weak ws] in
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                ws?.cancel(with: .abnormalClosure, reason: nil)
                throw LightRelayError.timeout
            }
            guard let result = try await group.next() else {
                throw LightRelayError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    func disconnect() {
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        logger.notice("[LightRelay] Disconnected")
    }

    func fetchEvents(filter: [String: Any], timeout: TimeInterval = 10.0) async throws -> [[String: Any]] {
        guard let ws = webSocket else { throw LightRelayError.notConnected }

        let subId = String(UUID().uuidString.prefix(8)).lowercased()
        let reqArray: [Any] = ["REQ", subId, filter]
        let reqData = try JSONSerialization.data(withJSONObject: reqArray)
        let reqString = String(data: reqData, encoding: .utf8)!

        try await ws.send(.string(reqString))
        logger.notice("[LightRelay] Sent REQ \(subId, privacy: .public)")

        var events: [[String: Any]] = []
        let deadline = Date().addingTimeInterval(timeout)

        receiveLoop: while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            do {
                let message = try await Self.receiveWithTimeout(ws: ws, timeout: remaining)

                switch message {
                case .string(let text):
                    guard let data = text.data(using: .utf8),
                          let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          let type = array.first as? String else {
                        logger.notice("[LightRelay] Could not parse message")
                        continue
                    }

                    if type == "EVENT", array.count >= 3,
                       let eventSubId = array[1] as? String, eventSubId == subId,
                       let event = array[2] as? [String: Any] {
                        logger.notice("[LightRelay] Got EVENT")
                        events.append(event)
                    } else if type == "EOSE" {
                        logger.notice("[LightRelay] EOSE received, \(events.count) events")
                        break receiveLoop
                    } else if type == "NOTICE" {
                        logger.notice("[LightRelay] NOTICE from relay")
                    } else {
                        logger.notice("[LightRelay] Other message type: \(type)")
                    }

                case .data(let data):
                    logger.notice("[LightRelay] Received binary data: \(data.count) bytes")
                    continue
                @unknown default:
                    continue
                }
            } catch {
                logger.error("[LightRelay] Receive error: \(error.localizedDescription)")
                break
            }
        }

        // Close subscription
        let closeArray: [Any] = ["CLOSE", subId]
        if let closeData = try? JSONSerialization.data(withJSONObject: closeArray),
           let closeString = String(data: closeData, encoding: .utf8) {
            try? await ws.send(.string(closeString))
        }

        return events
    }

    func publishEvent(event: [String: Any]) async throws -> Bool {
        guard let ws = webSocket else { throw LightRelayError.notConnected }

        let eventArray: [Any] = ["EVENT", event]
        let eventData = try JSONSerialization.data(withJSONObject: eventArray)
        let eventString = String(data: eventData, encoding: .utf8)!

        try await ws.send(.string(eventString))
        logger.notice("[LightRelay] Published event")

        // Wait for OK response, skip non-OK messages (NOTICE, EVENT, etc.), with timeout.
        // Use receiveWithTimeout so a silent relay that accepts the publish but never
        // sends OK cannot stall the caller (and the whole TaskGroup) forever.
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            do {
                let message = try await Self.receiveWithTimeout(ws: ws, timeout: remaining)
                switch message {
                case .string(let text):
                    guard let data = text.data(using: .utf8),
                          let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          let type = array.first as? String else {
                        continue
                    }
                    if type == "OK", array.count >= 3, let accepted = array[2] as? Bool {
                        logger.notice("[LightRelay] OK: \(accepted)")
                        return accepted
                    }
                    // NOTICE, EVENT, or other — skip and keep waiting
                    logger.notice("[LightRelay] Skipping \(type) while waiting for OK")
                default:
                    continue
                }
            } catch {
                logger.error("[LightRelay] Publish receive error: \(error.localizedDescription)")
                return false
            }
        }
        logger.warning("[LightRelay] Timed out waiting for OK")
        return false
    }
}

enum LightRelayError: LocalizedError {
    case invalidURL
    case notConnected
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid relay URL"
        case .notConnected: return "Not connected to relay"
        case .timeout: return "Relay operation timed out"
        }
    }
}
