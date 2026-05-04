import XCTest
import SwiftUI
@testable import Clave

final class AccountThemeTests: XCTestCase {

    // The palette must contain exactly 12 distinct entries (per spec).
    func testPalette_hasTwelveEntries() {
        XCTAssertEqual(AccountTheme.palette.count, 12)
    }

    // Same pubkey → same theme, every time. Critical for visual stability.
    func testForAccount_isDeterministic() {
        let pk = "d6a4f1b71acb4c0b989ed61a695cd438f219463d3983b5b457791e5e6d681449"
        let a = AccountTheme.forAccount(pubkeyHex: pk)
        let b = AccountTheme.forAccount(pubkeyHex: pk)
        XCTAssertEqual(a.paletteIndex, b.paletteIndex)
    }

    // Different pubkeys typically map to different themes (not a hard guarantee
    // — palette is finite, collisions exist — but across N=100 random pubkeys
    // we should see at least 8 of the 12 themes hit. Validates distribution.
    func testForAccount_distributesAcrossPalette() {
        var seen = Set<Int>()
        for _ in 0..<100 {
            let randomHex = (0..<32).map { _ in
                String(format: "%02x", UInt8.random(in: 0...255))
            }.joined()
            seen.insert(AccountTheme.forAccount(pubkeyHex: randomHex).paletteIndex)
        }
        XCTAssertGreaterThanOrEqual(seen.count, 8,
            "100 random pubkeys should hit at least 8 of 12 palette entries; got \(seen.count)")
    }

    // Empty hex string falls back to the first palette entry safely.
    func testForAccount_emptyHexReturnsFirstPaletteEntry() {
        let theme = AccountTheme.forAccount(pubkeyHex: "")
        XCTAssertEqual(theme.paletteIndex, 0)
    }

    // Non-hex / malformed input also falls back safely.
    func testForAccount_invalidInputReturnsFirstPaletteEntry() {
        let theme = AccountTheme.forAccount(pubkeyHex: "not-hex-at-all")
        XCTAssertEqual(theme.paletteIndex, 0)
    }

    // Lowercase + uppercase + mixed case of the same pubkey produce the same theme.
    func testForAccount_isCaseInsensitive() {
        let lower = "d6a4f1b71acb4c0b989ed61a695cd438f219463d3983b5b457791e5e6d681449"
        let upper = lower.uppercased()
        XCTAssertEqual(
            AccountTheme.forAccount(pubkeyHex: lower).paletteIndex,
            AccountTheme.forAccount(pubkeyHex: upper).paletteIndex
        )
    }
}
