import Foundation

/// Builds the one-line `signedSummary` string stored on `ActivityEntry`. Pure
/// function, no storage I/O — caller passes in the kind:3 snapshot if relevant.
/// Output is ≤120 chars and contains no plaintext event content (only kind +
/// tag-derived references). User-visible references are truncated hex with type
/// prefixes (`@<truncated>` for pubkeys, `e:<truncated>` for event ids); pet
/// names for *connected clients* are resolved at view time using
/// `entry.clientPubkey`, not embedded here.
enum ActivitySummary {
    /// Maximum number of `p` tags we'll diff against the prior contact set
    /// before falling back to a non-diff summary. Caps NSE memory pressure
    /// for pathological accounts (5000+ follows). 99%+ of users sit well
    /// under this.
    static let kind3DiffCap = 2000

    /// Hard upper bound on the stored summary string. Most paths produce
    /// well under this; cap exists as a backstop against unbounded tag
    /// values (e.g., a relay URL containing a query string in kind:22242).
    static let maxLength = 120

    static func signedSummary(
        kind: Int,
        tags: [[String]],
        previousContactSet: Set<String>? = nil
    ) -> String? {
        let raw: String
        switch kind {
        case 0: raw = "Updated profile"
        case 1: raw = summarizeKind1(tags: tags)
        case 3: raw = summarizeKind3(tags: tags, previous: previousContactSet)
        case 4, 14, 1059: raw = summarizeDM(tags: tags)
        case 6: raw = summarizeRefEvent(prefix: "Reposted", tags: tags)
        case 7: raw = summarizeRefEvent(prefix: "Reacted to", tags: tags)
        case 9734: raw = summarizeRefUser(prefix: "Zap request to", tags: tags)
        case 10002:
            let n = countTags(tags, named: "r")
            raw = "Relay list (\(n) relay\(n == 1 ? "" : "s"))"
        case 22242: raw = summarizeKind22242(tags: tags)
        case 30023: raw = summarizeKind30023(tags: tags)
        case 30078: raw = summarizeKind30078(tags: tags)
        default: raw = "Kind \(kind)"
        }
        return cap(raw)
    }

    // MARK: - Per-kind builders

    private static func summarizeKind1(tags: [[String]]) -> String {
        var parts: [String] = []
        if let e = firstTag(tags, named: "e") {
            parts.append("Reply to e:\(truncated(e))")
        } else {
            parts.append("New note")
        }
        let pTags = tags.compactMap { tag -> String? in
            guard tag.first == "p", tag.count >= 2 else { return nil }
            return tag[1]
        }
        if let firstP = pTags.first {
            if pTags.count == 1 {
                parts.append("@\(truncated(firstP))")
            } else {
                parts.append("@\(truncated(firstP)) +\(pTags.count - 1)")
            }
        }
        let tTags = tags.compactMap { tag -> String? in
            guard tag.first == "t", tag.count >= 2 else { return nil }
            return tag[1]
        }
        if !tTags.isEmpty {
            if tTags.count <= 2 {
                parts.append(tTags.map { "#\($0)" }.joined(separator: " "))
            } else {
                parts.append(tTags.prefix(2).map { "#\($0)" }.joined(separator: " ") + " +\(tTags.count - 2)")
            }
        }
        return parts.joined(separator: " · ")
    }

    private static func summarizeKind3(tags: [[String]], previous: Set<String>?) -> String {
        let newSet: Set<String> = Set(tags.compactMap { tag -> String? in
            guard tag.first == "p", tag.count >= 2 else { return nil }
            return tag[1]
        })
        let count = newSet.count

        if count > kind3DiffCap {
            return "Updated contact list (\(count) follow\(count == 1 ? "" : "s"))"
        }
        guard let previous else {
            return "Set contact list (\(count) follow\(count == 1 ? "" : "s"))"
        }

        let added = newSet.subtracting(previous)
        let removed = previous.subtracting(newSet)

        if added.isEmpty && removed.isEmpty {
            return "Republished contact list (\(count) follow\(count == 1 ? "" : "s"))"
        }

        let totalChanges = added.count + removed.count
        if totalChanges > 3 {
            return "Contacts +\(added.count) / -\(removed.count)"
        }

        if added.count == 1 && removed.isEmpty {
            return "Followed @\(truncated(added.first!))"
        }
        if removed.count == 1 && added.isEmpty {
            return "Unfollowed @\(truncated(removed.first!))"
        }
        return "Contacts +\(added.count) / -\(removed.count)"
    }

    private static func summarizeDM(tags: [[String]]) -> String {
        if let p = firstTag(tags, named: "p") {
            return "DM to @\(truncated(p))"
        }
        return "DM"
    }

    private static func summarizeRefEvent(prefix: String, tags: [[String]]) -> String {
        if let e = firstTag(tags, named: "e") {
            return "\(prefix) e:\(truncated(e))"
        }
        return prefix
    }

    private static func summarizeRefUser(prefix: String, tags: [[String]]) -> String {
        if let p = firstTag(tags, named: "p") {
            return "\(prefix) @\(truncated(p))"
        }
        return prefix
    }

    private static func summarizeKind22242(tags: [[String]]) -> String {
        if let relay = firstTag(tags, named: "relay"), !relay.isEmpty {
            return "Authed to \(relay)"
        }
        return "Relay auth"
    }

    private static func summarizeKind30023(tags: [[String]]) -> String {
        guard let title = firstTag(tags, named: "title"), !title.isEmpty else {
            return "Article"
        }
        let trimmed: String
        if title.count > 60 {
            trimmed = String(title.prefix(59)) + "…"
        } else {
            trimmed = title
        }
        return "Article: \"\(trimmed)\""
    }

    private static func summarizeKind30078(tags: [[String]]) -> String {
        if let d = firstTag(tags, named: "d"), !d.isEmpty {
            return "App data (\(d))"
        }
        return "App data"
    }

    // MARK: - Helpers

    private static func firstTag(_ tags: [[String]], named name: String) -> String? {
        for tag in tags where tag.first == name && tag.count >= 2 {
            return tag[1]
        }
        return nil
    }

    private static func countTags(_ tags: [[String]], named name: String) -> Int {
        tags.reduce(0) { $0 + ($1.first == name ? 1 : 0) }
    }

    private static func truncated(_ hex: String) -> String {
        guard hex.count > 12 else { return hex }
        return String(hex.prefix(8)) + "…" + String(hex.suffix(4))
    }

    private static func cap(_ s: String) -> String {
        guard s.count > maxLength else { return s }
        return String(s.prefix(maxLength - 1)) + "…"
    }
}
