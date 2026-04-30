import Foundation

/// NIP-19 bech32-encoded entity references. Just the encoders we need —
/// `note` (event id only) and `nevent` (event id + optional relay hints +
/// optional author + optional kind, TLV-encoded). Decoders live in
/// `Bech32.decode`.
///
/// Used by `ActivityDetailView` to build "Open on njump.me" links. njump
/// accepts either `note1…` or `nevent1…`; `nevent` is preferred when we
/// have relay hints because it makes njump's lookup faster and more
/// reliable.
enum Nip19 {
    enum EncodeError: Error {
        case invalidHexLength
        case invalidHex
    }

    // TLV type bytes per NIP-19
    private static let tlvSpecial: UInt8 = 0
    private static let tlvRelay: UInt8 = 1
    private static let tlvAuthor: UInt8 = 2
    private static let tlvKind: UInt8 = 3

    /// Bech32-encode a 32-byte event id with HRP `note`. Simplest form,
    /// no TLV — just the raw 32 bytes.
    static func encodeNote(eventId: String) throws -> String {
        guard eventId.count == 64, let data = Data(hexString: eventId), data.count == 32 else {
            throw EncodeError.invalidHexLength
        }
        return try Bech32.encode(hrp: "note", data: data)
    }

    /// Bech32-encode a `nevent` TLV reference with optional relay hints,
    /// author, and kind. Relay hints help njump (and other clients) find
    /// the event faster — pass the connection's known relays, capped at 2.
    static func encodeNevent(
        eventId: String,
        relays: [String] = [],
        author: String? = nil,
        kind: Int? = nil
    ) throws -> String {
        guard eventId.count == 64, let idBytes = Data(hexString: eventId), idBytes.count == 32 else {
            throw EncodeError.invalidHexLength
        }

        var tlv = Data()
        // 0x00: event id (32 bytes, required)
        tlv.append(tlvSpecial)
        tlv.append(UInt8(idBytes.count))
        tlv.append(idBytes)

        // 0x01: relay URLs (optional, repeatable, ASCII bytes)
        for relay in relays.prefix(2) {
            guard let relayBytes = relay.data(using: .ascii), relayBytes.count <= 255 else { continue }
            tlv.append(tlvRelay)
            tlv.append(UInt8(relayBytes.count))
            tlv.append(relayBytes)
        }

        // 0x02: author pubkey (optional, 32 bytes)
        if let author, author.count == 64,
           let authorBytes = Data(hexString: author), authorBytes.count == 32 {
            tlv.append(tlvAuthor)
            tlv.append(UInt8(authorBytes.count))
            tlv.append(authorBytes)
        }

        // 0x03: kind (optional, 4 bytes big-endian)
        if let kind {
            tlv.append(tlvKind)
            tlv.append(0x04)
            let k = UInt32(bitPattern: Int32(kind))
            tlv.append(UInt8((k >> 24) & 0xff))
            tlv.append(UInt8((k >> 16) & 0xff))
            tlv.append(UInt8((k >> 8) & 0xff))
            tlv.append(UInt8(k & 0xff))
        }

        return try Bech32.encode(hrp: "nevent", data: tlv)
    }
}
