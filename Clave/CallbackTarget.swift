import Foundation

/// The `callback=` return leg: whether a partner's callback may be shown on
/// ApprovalSheet, and whether Clave may open it once the user approves.
/// From the Sign in with Clave spec, the `callback=` row.
///
/// Two rules, both pure and both enforced here so that "dropped" always means
/// *neither shown nor opened* — there is one gate, not two that could drift:
///
/// - **Exact host, no collapse.** An http(s) callback must resolve to exactly
///   the same host as the caller's self-asserted `url`, compared through
///   `CallerIdentity.domain(fromURL:)`. No registrable-domain collapse, so
///   `attacker.github.io` can never call back as `github.io`, and two tenants
///   of one shared suffix (`*.pages.dev`, `*.vercel.app`) can never redirect
///   to each other. Custom schemes have no host to compare and are taken as
///   given — the scheme itself is the claim.
/// - **Foreground approval only.** Never on denial, and never from the
///   lock-screen / NSE signing path, which has no foreground approval behind
///   it (and does not compile this file).
///
/// Like `CallerIdentity`, this is not a trust boundary: the caller's `url` is
/// itself self-asserted. Binding the callback to it only guarantees that the
/// return leg goes to the same place the sheet *showed*, so a user who read
/// the sheet is not sent somewhere else.
///
/// The callback must carry nothing sensitive — no secret, no signer pubkey,
/// no ack, only an opaque nonce the partner minted. A custom scheme is
/// squattable by any installed app and an https URL lands in browser history,
/// so a hijacked callback must cost an app switch, not a session. That is a
/// contract on partners, documented in `integrations.md`; Clave cannot
/// enforce it, and deliberately adds nothing of its own to the URL.
enum CallbackTarget {

    /// Where the return decision is being made.
    enum Origin: Equatable {
        /// The in-app ApprovalSheet, with the user looking at it.
        case approvalSheet
        /// The NSE / lock-screen signing path. Never returns.
        case lockScreen
    }

    /// What should happen once the handshake finishes.
    enum Outcome: Equatable {
        /// Do nothing — no callback, dropped, denied, or not a foreground approval.
        case noReturn
        /// Show "Return to *host*" rather than opening: an https callback
        /// opens a *new* Safari tab, not the tab holding the pending pairing,
        /// so auto-opening it would strand the user on a second, empty tab.
        case hint(host: String)
        /// Open it — a custom-scheme callback returns to the exact app instance.
        case open(url: String)
    }

    /// The callback with every rule applied, or nil when it must be dropped.
    /// The single source of truth: display and open both go through it.
    static func resolved(callback: String?, callerURL: String?) -> String? {
        guard let callback, let scheme = scheme(of: callback) else { return nil }

        guard scheme == "http" || scheme == "https" else {
            return callback  // custom scheme: no host to bind, opened as given
        }

        guard let callbackHost = CallerIdentity.domain(fromURL: callback),
              let callerHost = CallerIdentity.domain(fromURL: callerURL),
              callbackHost == callerHost else {
            return nil
        }
        return callback
    }

    /// What ApprovalSheet shows as the return target, domain-first like the
    /// caller headline: the host for http(s), else the bare scheme. Nil when
    /// the callback is dropped — a dropped callback is never shown.
    static func displayTarget(callback: String?, callerURL: String?) -> String? {
        guard let resolved = resolved(callback: callback, callerURL: callerURL) else { return nil }
        if let host = CallerIdentity.domain(fromURL: resolved) { return host }
        guard let scheme = scheme(of: resolved) else { return nil }
        return scheme + "://"
    }

    /// The line ApprovalSheet shows *before* approval, naming where approving
    /// will send the user. Nil when there is no callback or it was dropped —
    /// a refused callback is not surfaced at all.
    static func sheetDisclosure(callback: String?, callerURL: String?) -> String? {
        guard let target = displayTarget(callback: callback, callerURL: callerURL) else { return nil }
        return "Returns you to \(target)"
    }

    /// The whole return decision, as one pure function.
    static func outcome(
        callback: String?,
        callerURL: String?,
        approved: Bool,
        origin: Origin
    ) -> Outcome {
        guard approved,
              origin == .approvalSheet,
              let resolved = resolved(callback: callback, callerURL: callerURL) else {
            return .noReturn
        }
        // `domain(fromURL:)` is non-nil only for http(s) — exactly the callers
        // that would land in a new tab.
        if let host = CallerIdentity.domain(fromURL: resolved) {
            return .hint(host: host)
        }
        return .open(url: resolved)
    }

    /// Lowercased scheme of a callback, or nil when there isn't one. Matches
    /// `NostrConnectParser.sanitizedCallback`'s notion of a scheme so the two
    /// halves of the rule agree on what they are looking at.
    private static func scheme(of callback: String) -> String? {
        guard let colon = callback.firstIndex(of: ":") else { return nil }
        let scheme = callback[callback.startIndex..<colon].lowercased()
        guard let first = scheme.first, first.isASCII, first.isLetter else { return nil }
        return scheme
    }
}
