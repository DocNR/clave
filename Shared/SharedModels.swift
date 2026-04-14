import Foundation

struct ActivityEntry: Codable, Identifiable {
    let id: String
    let method: String
    let eventKind: Int?
    let clientPubkey: String
    let timestamp: Double
    let status: String       // "signed", "blocked", "error"
    let errorMessage: String?
}

/// A signing request for a protected kind, queued by the NSE for in-app approval.
struct PendingRequest: Codable, Identifiable {
    let id: String              // UUID
    let requestEventJSON: String // full relay event JSON (encrypted content, pubkey, etc.)
    let method: String
    let eventKind: Int?
    let clientPubkey: String
    let timestamp: Double
}

struct ConnectedClient: Codable, Identifiable {
    var id: String { pubkey }
    let pubkey: String
    var name: String?
    let firstSeen: Double
    var lastSeen: Double
    var requestCount: Int
}
