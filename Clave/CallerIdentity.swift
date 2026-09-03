import Foundation

/// Pure rules behind the domain-first caller rendering shared by
/// `ApprovalSheet.clientHeader` and the onboarding caller banner
/// (`OnboardingView.callerBanner`). From the Sign in with Clave spec,
/// "Domain-first ApprovalSheet rendering":
///
/// - the host of the caller's self-asserted `url` is the largest, most
///   prominent element — shown in full (minus a leading `www.`), ASCII-only,
///   never collapsed to a "registrable" part;
/// - the self-asserted `name` / `image` never take the headline: they are
///   rendered smaller, below, and explicitly marked unverified;
/// - when there is no usable url the headline is the client-pubkey
///   fingerprint, never the name.
///
/// Nothing self-asserted is given authority — brand-new users are the most
/// phishable audience. This is NOT a security boundary: the `url` is itself
/// self-asserted metadata; a real verified-caller badge is a later
/// well-known-JSON feature. These helpers only decide *what to make big*.
enum CallerIdentity {

    /// The fixed marker that follows every self-asserted claim ("calls itself
    /// “…”", "icon"). Rendered as its own sibling Text so a long name can be
    /// tail-truncated without pushing this off screen.
    static let unverifiedMarker = "· unverified"

    /// Characters a displayable host may contain, after lowercasing. Anything
    /// else — raw Unicode, percent-escapes, brackets, colons — yields nil.
    private static let hostCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")

    /// Display host of a self-asserted `url`, or nil when there is no host
    /// worth showing: missing/blank/unparseable URL, non-http(s) scheme, IP
    /// literal, `localhost`, single-label host (LAN/intranet names), or any
    /// host that is not plain ASCII `[a-z0-9.-]`.
    ///
    /// The host is taken from the URL string *as written* — not from
    /// `URLComponents.host` / `.percentEncodedHost`, which IDNA-decode a
    /// punycode `xn--80ak8a1oqq.casa` into a Cyrillic "сӏаѵе.casa" that is
    /// pixel-identical to clave.casa, and let zero-width / bidi-override /
    /// soft-hyphen characters through. Punycode is shown literally (visibly
    /// not the real domain); raw Unicode and percent-escapes are rejected.
    ///
    /// Host handling: lowercase; drop a trailing dot; strip exactly one
    /// leading `www.`; keep every other label — a last-two-labels collapse
    /// would launder `attacker.github.io` into "github.io" (likewise
    /// pages.dev, vercel.app, netlify.app, trycloudflare.com, ne.jp, nhs.uk…).
    /// Userinfo, ports, paths, queries and fragments are ignored.
    static func domain(fromURL urlString: String?) -> String? {
        guard let urlString,
              let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let schemeEnd = urlString.range(of: "://") else {
            return nil
        }

        // Authority = everything after "://" up to the first "/", "?" or "#";
        // then drop userinfo (through the last "@") and the port (from the
        // first ":" — an IPv6 literal's "[" fails the character check below).
        var authority = urlString[schemeEnd.upperBound...]
        if let end = authority.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            authority = authority[..<end]
        }
        if let at = authority.lastIndex(of: "@") {
            authority = authority[authority.index(after: at)...]
        }
        if let colon = authority.firstIndex(of: ":") {
            authority = authority[..<colon]
        }

        // ASCII check BEFORE lowercasing: a few non-ASCII letters (the Kelvin
        // sign, for one) lowercase to ASCII.
        guard authority.utf8.allSatisfy({ $0 < 128 }) else { return nil }
        var host = authority.lowercased()
        guard !host.isEmpty, host.allSatisfy(hostCharacters.contains) else { return nil }

        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }

        guard host != "localhost", !isIPv4Literal(host) else { return nil }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        return host
    }

    /// Short client-pubkey fingerprint, same shape as `ClientIdentityHeader`:
    /// first 8 hex chars, an ellipsis, last 4. Keys of 12 chars or fewer are
    /// returned unchanged (nothing to elide).
    static func fingerprint(_ pubkey: String) -> String {
        guard pubkey.count > 12 else { return pubkey }
        return String(pubkey.prefix(8)) + "…" + String(pubkey.suffix(4))
    }

    /// The headline for the caller: the display host when the `url` yields
    /// one, else the pubkey fingerprint. The self-asserted name is not an
    /// input — it must never occupy the headline slot.
    static func headline(url: String?, pubkey: String) -> String {
        domain(fromURL: url) ?? fingerprint(pubkey)
    }

    /// The self-asserted name with surrounding whitespace trimmed; nil when
    /// absent or whitespace-only. Every surface goes through this so a blank
    /// name is "no name" everywhere.
    static func name(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The self-asserted claim shown beneath the headline, always followed by
    /// `unverifiedMarker`: 'calls itself “name”' when a name is present; else
    /// "icon" when only an image is (an icon-only caller is still making a
    /// claim); else nil (nothing self-asserted to flag). Shared by both
    /// surfaces so identical inputs produce identical strings.
    static func unverifiedClaim(name rawName: String?, imageURL: String?) -> String? {
        if let name = name(rawName) {
            return "calls itself “\(name)”"
        }
        if let imageURL, !imageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "icon"
        }
        return nil
    }

    // MARK: - Private

    /// Exactly four all-digit labels. (IPv6 literals never reach here — their
    /// brackets and colons fail the host character check.)
    private static func isIPv4Literal(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
