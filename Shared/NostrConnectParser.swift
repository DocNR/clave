import Foundation

enum NostrConnectParser {

    enum ParseError: Error, Equatable {
        case invalidScheme
        case missingPubkey
        case missingRelay
        case missingSecret
        case invalidURL
    }

    struct ParsedURI: Identifiable {
        var id: String { clientPubkey + secret }
        let clientPubkey: String
        let relays: [String]
        let secret: String
        let requestedPerms: [String]
        let name: String?
        let url: String?
        let imageURL: String?
        let suggestedTrustLevel: TrustLevel
    }

    static func parse(_ uri: String) throws -> ParsedURI {
        guard uri.hasPrefix("nostrconnect://") else {
            throw ParseError.invalidScheme
        }

        let httpURI = "https://" + uri.dropFirst("nostrconnect://".count)
        guard let components = URLComponents(string: httpURI) else {
            throw ParseError.invalidURL
        }

        let clientPubkey = components.host ?? ""
        guard !clientPubkey.isEmpty else { throw ParseError.missingPubkey }

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
            suggestedTrustLevel: suggestedTrustLevel
        )
    }
}
