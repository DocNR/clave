import Foundation

enum NostrConnectParser {

    enum ParseError: Error, Equatable {
        case invalidScheme
        case missingPubkey
        case invalidPubkey
        case missingRelay
        case missingSecret
        case invalidURL
    }

    struct ParsedURI: Identifiable, Codable {
        var id: String { clientPubkey + secret }
        let clientPubkey: String
        let relays: [String]
        let secret: String
        let requestedPerms: [String]
        let name: String?
        let url: String?
        let imageURL: String?
        let suggestedTrustLevel: TrustLevel
        let isMultiAccount: Bool
        /// The partner's return-leg target, already scheme-validated by
        /// `sanitizedCallback` (nil when absent or rejected). Whether it may
        /// be *shown or opened* is a further decision — an https callback must
        /// also match the caller's `url` host — and lives in `CallbackTarget`,
        /// which needs `CallerIdentity` and is therefore app-target only. The
        /// NSE compiles this file too and must never open a callback at all.
        let callback: String?
        /// Set at onboarding-promotion time on the in-memory replay payload
        /// (true iff the key was Generated during a Sign-in-with-Clave flow;
        /// false for import and every non-onboarding route). Deliberately
        /// excluded from `CodingKeys` so it is NEVER persisted — it dies with
        /// the replay, per the spec's data-integrity rule. Read by
        /// ApprovalSheet (Phase 2 signup write-set consent).
        var createdDuringFlow: Bool = false

        /// Persistable fields only. `createdDuringFlow` is intentionally
        /// omitted so a stashed URI can never carry a stale/forged consent
        /// flag across the App Store round trip; `id` is computed.
        enum CodingKeys: String, CodingKey {
            case clientPubkey, relays, secret, requestedPerms
            case name, url, imageURL, suggestedTrustLevel, isMultiAccount
            case callback
        }
    }

    private static let hexDigits = Set("0123456789abcdef")

    /// Schemes never handed to `UIApplication.open`, whatever else is true of
    /// the callback.
    private static let rejectedCallbackSchemes: Set<String> = ["javascript", "data", "file"]

    /// Whitespace and control characters anywhere in a callback make it
    /// un-trustworthy to reason about (`java\u{0A}script:` and friends), so
    /// the whole value is dropped rather than sanitised.
    private static let forbiddenCallbackCharacters = CharacterSet.whitespacesAndNewlines
        .union(.controlCharacters)

    /// Scheme-level validation of a raw `callback=` value: returns the trimmed
    /// callback when it is *shaped* like something safe to open, else nil.
    ///
    /// Kept: any RFC-3986-shaped scheme that is not `javascript:`, `data:` or
    /// `file:`, carries no userinfo, and contains no whitespace or control
    /// characters. Dropped: everything else, including a scheme-less value —
    /// a bare `example.com/return` is too ambiguous to act on.
    ///
    /// This is deliberately only half the rule. The host-equality check for
    /// http(s) callbacks lives in `CallbackTarget` (app target); see the
    /// `callback` property's note.
    static func sanitizedCallback(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: forbiddenCallbackCharacters) == nil,
              let colon = trimmed.firstIndex(of: ":") else {
            return nil
        }

        // Scheme: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ), ASCII only.
        let scheme = trimmed[trimmed.startIndex..<colon].lowercased()
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") }),
              !rejectedCallbackSchemes.contains(scheme) else {
            return nil
        }

        // Userinfo is only possible in a "//"-introduced authority, which ends
        // at the first "/", "?" or "#" — an "@" past that is path/query data.
        let afterScheme = trimmed[trimmed.index(after: colon)...]
        if afterScheme.hasPrefix("//") {
            var authority = afterScheme.dropFirst(2)
            if let end = authority.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
                authority = authority[..<end]
            }
            guard !authority.contains("@") else { return nil }
        }

        return trimmed
    }

    static func parse(_ uri: String) throws -> ParsedURI {
        guard uri.hasPrefix("nostrconnect://") else {
            throw ParseError.invalidScheme
        }

        let httpURI = "https://" + uri.dropFirst("nostrconnect://".count)
        guard let components = URLComponents(string: httpURI) else {
            throw ParseError.invalidURL
        }

        let clientPubkey = (components.host ?? "").lowercased()
        guard !clientPubkey.isEmpty else { throw ParseError.missingPubkey }
        // The host IS the client pubkey: exactly 64 hex characters, stored
        // lowercased. Anything else — a domain name, a short key, a non-hex
        // character — is a malformed URI, however well-formed its relay and
        // secret are.
        guard clientPubkey.utf8.count == 64, clientPubkey.allSatisfy(hexDigits.contains) else {
            throw ParseError.invalidPubkey
        }

        let queryItems = components.queryItems ?? []

        let relays = queryItems.filter { $0.name == "relay" }.compactMap { $0.value }
        guard !relays.isEmpty else { throw ParseError.missingRelay }

        guard let secret = queryItems.first(where: { $0.name == "secret" })?.value, !secret.isEmpty else {
            throw ParseError.missingSecret
        }

        let permsString = queryItems.first(where: { $0.name == "perms" })?.value ?? ""
        let requestedPerms = permsString.isEmpty ? [] : permsString.components(separatedBy: ",")

        let name = queryItems.first(where: { $0.name == "name" })?.value
        let url = queryItems.first(where: { $0.name == "url" })?.value
        let imageURL = queryItems.first(where: { $0.name == "image" })?.value

        let callback = sanitizedCallback(queryItems.first(where: { $0.name == "callback" })?.value)

        let accountsParam = queryItems.first(where: { $0.name == "accounts" })?.value
        let isMultiAccount = accountsParam == "multi"

        let suggestedTrustLevel: TrustLevel
        if requestedPerms.isEmpty {
            suggestedTrustLevel = .medium
        } else if requestedPerms.count <= 3 {
            suggestedTrustLevel = .low
        } else {
            suggestedTrustLevel = .medium
        }

        return ParsedURI(
            clientPubkey: clientPubkey,
            relays: relays,
            secret: secret,
            requestedPerms: requestedPerms,
            name: name,
            url: url,
            imageURL: imageURL,
            suggestedTrustLevel: suggestedTrustLevel,
            isMultiAccount: isMultiAccount,
            callback: callback
        )
    }
}
