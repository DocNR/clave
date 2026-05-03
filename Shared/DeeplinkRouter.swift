import Foundation

/// Pure routing function for incoming URL deeplinks. Maps a URL +
/// current AppState.accounts.count to a routing decision the AppState
/// observer can act on. Pure for testability — no side effects.
enum DeeplinkRouter {

    enum Outcome: Equatable {
        /// Single-account: route directly to ApprovalSheet.
        case approve(NostrConnectParser.ParsedURI)
        /// Multi-account: route to DeeplinkAccountPicker first.
        case pickAccount(NostrConnectParser.ParsedURI)
        /// No-op (clave:// reserved, malformed URIs, unsupported schemes,
        /// or zero-account defensive case).
        case ignore

        static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            switch (lhs, rhs) {
            case (.ignore, .ignore): return true
            case (.approve(let a), .approve(let b)): return a.id == b.id
            case (.pickAccount(let a), .pickAccount(let b)): return a.id == b.id
            default: return false
            }
        }
    }

    static func route(url: URL, accountCount: Int) -> Outcome {
        switch url.scheme {
        case "nostrconnect":
            guard let parsed = try? NostrConnectParser.parse(url.absoluteString) else {
                return .ignore
            }
            if accountCount <= 0 { return .ignore }
            if accountCount == 1 { return .approve(parsed) }
            return .pickAccount(parsed)
        case "clave":
            // Reserved namespace — no handlers yet.
            return .ignore
        default:
            return .ignore
        }
    }
}
