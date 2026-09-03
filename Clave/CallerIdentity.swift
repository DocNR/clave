import Foundation

/// Pure rules behind the domain-first caller rendering shared by
/// `ApprovalSheet.clientHeader` and the onboarding caller banner
/// (`OnboardingView.callerBanner`). From the Sign in with Clave spec,
/// "Domain-first ApprovalSheet rendering":
///
/// - the registrable domain of the caller's self-asserted `url` is the
///   largest, most prominent element;
/// - the self-asserted `name` / `image` are rendered smaller, below, and
///   explicitly marked unverified;
/// - a short client-pubkey fingerprint is always available.
///
/// Nothing self-asserted is given authority — brand-new users are the most
/// phishable audience. This is NOT a security boundary: the `url` is itself
/// self-asserted metadata; a real verified-caller badge is a later
/// well-known-JSON feature. These helpers only decide *what to make big*.
enum CallerIdentity {

    /// Second-level labels that are themselves public suffixes under a
    /// 2-letter country TLD ("co.uk", "com.au", "ac.jp", "gov.br", …).
    /// Deliberately small and conservative — this is not the Public Suffix
    /// List, just enough to keep "example.co.uk" from collapsing to "co.uk".
    private static let wellKnownSecondLevelSuffixes: Set<String> = [
        "co", "com", "org", "net", "gov", "ac", "edu", "mil",
    ]

    /// Registrable domain of a self-asserted `url`, or nil when there is no
    /// domain worth showing: missing/blank/unparseable URL, non-http(s)
    /// scheme, IP literal, `localhost`, or a single-label host (no public
    /// suffix — LAN/intranet names).
    ///
    /// Host handling: lowercase; drop a trailing dot; strip one leading
    /// `www.`; collapse subdomains to the last two labels, or the last three
    /// when the second-to-last label is a well-known second-level suffix
    /// under a 2-letter TLD ("app.example.co.uk" → "example.co.uk",
    /// "shop.conduit.market" → "conduit.market"). Ports and paths are
    /// ignored.
    static func registrableDomain(fromURL urlString: String?) -> String? {
        guard let urlString,
              !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let rawHost = components.host, !rawHost.isEmpty else {
            return nil
        }

        var host = rawHost.lowercased()
        // Some Foundation versions keep IPv6 brackets in `host`; normalise
        // before the IP-literal check.
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }

        guard host != "localhost", !isIPLiteral(host) else { return nil }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return nil }

        let tld = labels[labels.count - 1]
        let secondLevel = labels[labels.count - 2]
        let keepThree = labels.count >= 3
            && tld.count == 2
            && wellKnownSecondLevelSuffixes.contains(secondLevel)
        return labels.suffix(keepThree ? 3 : 2).joined(separator: ".")
    }

    /// Short client-pubkey fingerprint, same shape as `ClientIdentityHeader`:
    /// first 8 hex chars, an ellipsis, last 4. Keys of 12 chars or fewer are
    /// returned unchanged (nothing to elide).
    static func fingerprint(_ pubkey: String) -> String {
        guard pubkey.count > 12 else { return pubkey }
        return String(pubkey.prefix(8)) + "…" + String(pubkey.suffix(4))
    }

    /// The headline for the caller: the registrable domain when the `url`
    /// yields one; else the self-asserted name (still unverified — callers
    /// must keep the "unverified" caption visible); else the pubkey
    /// fingerprint. An empty name is treated as absent.
    static func displayDomain(for uri: NostrConnectParser.ParsedURI) -> String {
        if let domain = registrableDomain(fromURL: uri.url) {
            return domain
        }
        if let name = uri.name, !name.isEmpty {
            return name
        }
        return fingerprint(uri.clientPubkey)
    }

    // MARK: - Private

    /// IPv6 literals contain ":"; IPv4 literals are exactly four all-digit
    /// labels. Anything else is treated as a hostname.
    private static func isIPLiteral(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
