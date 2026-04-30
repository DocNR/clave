import XCTest
@testable import Clave

final class Bech32EncodeTests: XCTestCase {

    // MARK: - Known fixtures

    /// Test account npub from project memory:
    /// hex pubkey 55127fc9...ed9b21 ↔ npub125f8lj0pcq7xk3v68w4h9ldenhh3v3x97gumm5yl8e0mgq0dnvssjptd2l
    func testEncodeNpubMatchesKnownFixture() throws {
        let hex = "55127fc9e1c03c6b459a3bab72fdb99def1644c5f239bdd09f3e5fb401ed9b21"
        let expected = "npub125f8lj0pcq7xk3v68w4h9ldenhh3v3x97gumm5yl8e0mgq0dnvssjptd2l"

        let data = Data(hexString: hex)!
        let encoded = try Bech32.encode(hrp: "npub", data: data)
        XCTAssertEqual(encoded, expected)
    }

    // MARK: - Round-trip

    func testRoundTripNpub() throws {
        let hex = "55127fc9e1c03c6b459a3bab72fdb99def1644c5f239bdd09f3e5fb401ed9b21"
        let data = Data(hexString: hex)!
        let encoded = try Bech32.encode(hrp: "npub", data: data)
        let (hrp, decoded) = try Bech32.decode(encoded)
        XCTAssertEqual(hrp, "npub")
        XCTAssertEqual(decoded, data)
    }

    func testRoundTripNote() throws {
        // Arbitrary 32-byte event id
        let hex = "abc123def456789012345678901234567890123456789012345678901234abcd"
        let data = Data(hexString: hex)!
        let encoded = try Bech32.encode(hrp: "note", data: data)
        XCTAssertTrue(encoded.hasPrefix("note1"))
        let (hrp, decoded) = try Bech32.decode(encoded)
        XCTAssertEqual(hrp, "note")
        XCTAssertEqual(decoded, data)
    }

    func testRoundTripNevent() throws {
        // Arbitrary TLV-shaped payload (we'll exercise the full TLV in Nip19Tests;
        // this just confirms Bech32 round-trips arbitrary bytes with a long HRP).
        let bytes: [UInt8] = [
            0x00, 0x20,
            0xab, 0xc1, 0x23, 0xde, 0xf4, 0x56, 0x78, 0x90,
            0x12, 0x34, 0x56, 0x78, 0x90, 0x12, 0x34, 0x56,
            0x78, 0x90, 0x12, 0x34, 0x56, 0x78, 0x90, 0x12,
            0x34, 0x56, 0x78, 0x90, 0x12, 0x34, 0xab, 0xcd
        ]
        let data = Data(bytes)
        let encoded = try Bech32.encode(hrp: "nevent", data: data)
        XCTAssertTrue(encoded.hasPrefix("nevent1"))
        let (hrp, decoded) = try Bech32.decode(encoded)
        XCTAssertEqual(hrp, "nevent")
        XCTAssertEqual(decoded, data)
    }

    func testEncodeIsLowercase() throws {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        let encoded = try Bech32.encode(hrp: "NPUB", data: data)
        XCTAssertEqual(encoded, encoded.lowercased())
    }
}
