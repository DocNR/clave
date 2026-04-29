import Foundation
import OSLog

enum LogExporter {

    struct Entry: Equatable {
        let date: Date
        let category: String
        let message: String
    }

    /// Known log categories used across Clave's main app. NSE's "signer" category also
    /// writes under this subsystem but runs in a different process and is NOT captured
    /// by `.currentProcessIdentifier` scope.
    ///
    /// Keep this in sync with `Logger(subsystem: "dev.nostr.clave", category:)`
    /// declarations across `Shared/` and `Clave/`. Categories absent from this list
    /// are silently filtered out of "Copy Recent Logs" — the user becomes blind
    /// to that code path's activity.
    static let allCategories: [String] = [
        "relay", "signer", "storage", "apns", "app", "fg-sub", "banner", "nc-sweep"
    ]

    /// Fetch main-app logs from the unified log store within the given time window.
    /// Returns an empty array on failure (no exception — this is a debug convenience).
    static func fetchRecentLogs(since: Date) -> [Entry] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else {
            return []
        }
        let position = store.position(date: since)
        guard let allEntries = try? store.getEntries(at: position) else { return [] }
        return allEntries
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == "dev.nostr.clave" }
            .map { Entry(date: $0.date, category: $0.category, message: $0.composedMessage) }
    }

    /// Pure formatter — testable without OSLogStore.
    static func format(entries: [Entry], categories: Set<String>? = nil) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return entries
            .filter { entry in
                guard let categories else { return true }
                return categories.contains(entry.category)
            }
            .map { "\(formatter.string(from: $0.date)) [\($0.category)] \($0.message)" }
            .joined(separator: "\n")
    }

    /// Convenience overload accepting Array<String> for call-site ergonomics.
    static func format(entries: [Entry], categories: [String]) -> String {
        format(entries: entries, categories: Set(categories))
    }
}
