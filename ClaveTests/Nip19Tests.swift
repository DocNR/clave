import XCTest
@testable import Clave

final class Nip19Tests: XCTestCase {

    // MARK: - encodeNote

    func testEncodeNoteRoundTrips() throws {
        let eventId = "abc123def456789012345678901234567890123456789012345678901234abcd"
        let encoded = try Nip19.encodeNote(eventId: eventId)
        XCTAssertTrue(encoded.hasPrefix("note1"))

        let (hrp, data) = try Bech32.decode(encoded)
        XCTAssertEqual(hrp, "note")
        XCTAssertEqual(data, Data(hexString: eventId))
    }

    func testEncodeNoteRejectsShortHex() {
        XCTAssertThrowsError(try Nip19.encodeNote(eventId: "abc"))
    }

    func testEncodeNoteRejectsLongHex() {
        let tooLong = String(repeating: "a", count: 100)
        XCTAssertThrowsError(try Nip19.encodeNote(eventId: tooLong))
    }

    func testEncodeNoteRejectsNonHex() {
        let badHex = String(repeating: "z", count: 64)
        XCTAssertThrowsError(try Nip19.encodeNote(eventId: badHex))
    }

    // MARK: - encodeNevent

    func testEncodeNeventIdOnly() throws {
        let eventId = "abc123def456789012345678901234567890123456789012345678901234abcd"
        let encoded = try Nip19.encodeNevent(eventId: eventId)
        XCTAssertTrue(encoded.hasPrefix("nevent1"))

        let (hrp, tlv) = try Bech32.decode(encoded)
        XCTAssertEqual(hrp, "nevent")

        // Parse the TLV: should be exactly one entry — type 0x00, length 0x20, 32 bytes
        let parsed = parseTLV(tlv)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].type, 0x00)
        XCTAssertEqual(parsed[0].value, Data(hexString: eventId))
    }

    func testEncodeNeventWithRelayHints() throws {
        let eventId = "abc123def456789012345678901234567890123456789012345678901234abcd"
        let encoded = try Nip19.encodeNevent(
            eventId: eventId,
            relays: ["wss://relay.damus.io", "wss://nos.lol"]
        )
        let (_, tlv) = try Bech32.decode(encoded)
        let parsed = parseTLV(tlv)

        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed[0].type, 0x00)
        XCTAssertEqual(parsed[1].type, 0x01)
        XCTAssertEqual(String(data: parsed[1].value, encoding: .ascii), "wss://relay.damus.io")
        XCTAssertEqual(parsed[2].type, 0x01)
        XCTAssertEqual(String(data: parsed[2].value, encoding: .ascii), "wss://nos.lol")
    }

    func testEncodeNeventCapsRelaysAtTwo() throws {
        let eventId = "abc123def456789012345678901234567890123456789012345678901234abcd"
        let encoded = try Nip19.encodeNevent(
            eventId: eventId,
            relays: ["wss://r1.test", "wss://r2.test", "wss://r3.test", "wss://r4.test"]
        )
        let (_, tlv) = try Bech32.decode(encoded)
        let parsed = parseTLV(tlv)
        let relayCount = parsed.filter { $0.type == 0x01 }.count
        XCTAssertEqual(relayCount, 2)
    }

    func testEncodeNeventWithKind() throws {
        let eventId = "abc123def456789012345678901234567890123456789012345678901234abcd"
        let encoded = try Nip19.encodeNevent(eventId: eventId, kind: 1)

        let (_, tlv) = try Bech32.decode(encoded)
        let parsed = parseTLV(tlv)
        let kindEntry = parsed.first { $0.type == 0x03 }
        XCTAssertNotNil(kindEntry)
        XCTAssertEqual(kindEntry?.value.count, 4)

        // Big-endian decode
        let value = kindEntry!.value
        let kind = (UInt32(value[0]) << 24) | (UInt32(value[1]) << 16) |
                   (UInt32(value[2]) << 8) | UInt32(value[3])
        XCTAssertEqual(kind, 1)
    }

    func testEncodeNeventWithLargeKind() throws {
        let eventId = "abc123def456789012345678901234567890123456789012345678901234abcd"
        let encoded = try Nip19.encodeNevent(eventId: eventId, kind: 30023)

        let (_, tlv) = try Bech32.decode(encoded)
        let parsed = parseTLV(tlv)
        let kindEntry = parsed.first { $0.type == 0x03 }!
        let value = kindEntry.value
        let kind = (UInt32(value[0]) << 24) | (UInt32(value[1]) << 16) |
                   (UInt32(value[2]) << 8) | UInt32(value[3])
        XCTAssertEqual(kind, 30023)
    }

    func testEncodeNeventWithAuthor() throws {
        let eventId = "abc123def456789012345678901234567890123456789012345678901234abcd"
        let author = "55127fc9e1c03c6b459a3bab72fdb99def1644c5f239bdd09f3e5fb401ed9b21"
        let encoded = try Nip19.encodeNevent(eventId: eventId, author: author)

        let (_, tlv) = try Bech32.decode(encoded)
        let parsed = parseTLV(tlv)
        let authorEntry = parsed.first { $0.type == 0x02 }
        XCTAssertNotNil(authorEntry)
        XCTAssertEqual(authorEntry?.value, Data(hexString: author))
    }

    // MARK: - TLV parser (test-only)

    private struct TLVEntry {
        let type: UInt8
        let value: Data
    }

    private func parseTLV(_ data: Data) -> [TLVEntry] {
        var entries: [TLVEntry] = []
        var i = data.startIndex
        while i < data.endIndex {
            let type = data[i]
            i = data.index(after: i)
            guard i < data.endIndex else { break }
            let length = Int(data[i])
            i = data.index(after: i)
            let endIndex = data.index(i, offsetBy: length, limitedBy: data.endIndex) ?? data.endIndex
            let value = data.subdata(in: i..<endIndex)
            entries.append(TLVEntry(type: type, value: value))
            i = endIndex
        }
        return entries
    }
}
