import SwiftUI
import CryptoKit

/// Deterministic gradient palette for per-account visual identity.
///
/// Pubkey hex → SHA-256 → first 2 bytes → palette index. Same account
/// always gets the same gradient across launches and devices.
///
/// Used by AccountStripView (active pill ring), SlimIdentityBar (background
/// wash), HomeView (full-screen ambient gradient), AccountDetailView
/// (gradient banner header), ApprovalSheet (SigningAsHeader tint).
///
/// Palette is curated to avoid clashy hues, low-contrast pairs, and yellows
/// that look broken on white backgrounds. 12 entries — comfortably more than
/// the 5-account pairing cap, low collision probability for typical use.
struct AccountTheme: Equatable {
    let start: Color
    let end: Color
    let accent: Color
    let paletteIndex: Int  // exposed for tests + debugging

    /// Build a theme for a given account pubkey. Empty / invalid hex falls
    /// back to the first palette entry (defensive — should never fire in
    /// production since AppState guards against empty signerPubkeyHex).
    static func forAccount(pubkeyHex: String) -> AccountTheme {
        let normalized = pubkeyHex.lowercased()
        guard !normalized.isEmpty,
              normalized.allSatisfy({ $0.isHexDigit }) else {
            return palette[0]
        }
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let bytes = Array(digest)
        // Use first 2 bytes as a uint16, mod palette count for stable mapping.
        let index = (Int(bytes[0]) << 8 | Int(bytes[1])) % palette.count
        return palette[index]
    }

    /// 12 curated gradient pairs. Each entry: `(start, end, accent, index)`.
    /// Accent = darker / more saturated of the pair, used for text + active
    /// indicators. Indices are stable — never reorder this array (would
    /// reassign every existing account's color).
    static let palette: [AccountTheme] = [
        AccountTheme(start: Color(red: 0.48, green: 0.55, blue: 1.00),
                     end:   Color(red: 0.63, green: 0.29, blue: 1.00),
                     accent: Color(red: 0.35, green: 0.18, blue: 1.00),
                     paletteIndex: 0),  // purple/violet
        AccountTheme(start: Color(red: 0.00, green: 0.78, blue: 1.00),
                     end:   Color(red: 0.18, green: 1.00, blue: 0.71),
                     accent: Color(red: 0.00, green: 0.35, blue: 0.40),
                     paletteIndex: 1),  // teal/aqua
        AccountTheme(start: Color(red: 1.00, green: 0.55, blue: 0.29),
                     end:   Color(red: 1.00, green: 0.76, blue: 0.29),
                     accent: Color(red: 0.78, green: 0.35, blue: 0.00),
                     paletteIndex: 2),  // coral/amber
        AccountTheme(start: Color(red: 1.00, green: 0.29, blue: 0.55),
                     end:   Color(red: 1.00, green: 0.47, blue: 0.66),
                     accent: Color(red: 0.78, green: 0.10, blue: 0.40),
                     paletteIndex: 3),  // magenta/pink
        AccountTheme(start: Color(red: 0.29, green: 0.64, blue: 1.00),
                     end:   Color(red: 0.29, green: 0.91, blue: 1.00),
                     accent: Color(red: 0.10, green: 0.45, blue: 0.85),
                     paletteIndex: 4),  // sky/cyan
        AccountTheme(start: Color(red: 0.29, green: 1.00, blue: 0.55),
                     end:   Color(red: 0.76, green: 1.00, blue: 0.29),
                     accent: Color(red: 0.10, green: 0.55, blue: 0.20),
                     paletteIndex: 5),  // lime/grass
        AccountTheme(start: Color(red: 1.00, green: 0.42, blue: 0.42),
                     end:   Color(red: 1.00, green: 0.62, blue: 0.31),
                     accent: Color(red: 0.78, green: 0.18, blue: 0.18),
                     paletteIndex: 6),  // red/orange
        AccountTheme(start: Color(red: 0.55, green: 0.29, blue: 1.00),
                     end:   Color(red: 0.93, green: 0.42, blue: 1.00),
                     accent: Color(red: 0.40, green: 0.10, blue: 0.78),
                     paletteIndex: 7),  // violet/fuchsia
        AccountTheme(start: Color(red: 0.10, green: 0.78, blue: 0.60),
                     end:   Color(red: 0.40, green: 0.93, blue: 0.40),
                     accent: Color(red: 0.05, green: 0.40, blue: 0.30),
                     paletteIndex: 8),  // emerald/lime
        AccountTheme(start: Color(red: 0.78, green: 0.42, blue: 0.93),
                     end:   Color(red: 1.00, green: 0.55, blue: 0.78),
                     accent: Color(red: 0.55, green: 0.18, blue: 0.71),
                     paletteIndex: 9),  // orchid/pink
        AccountTheme(start: Color(red: 0.29, green: 0.42, blue: 0.85),
                     end:   Color(red: 0.55, green: 0.71, blue: 1.00),
                     accent: Color(red: 0.10, green: 0.20, blue: 0.65),
                     paletteIndex: 10), // navy/blue
        AccountTheme(start: Color(red: 1.00, green: 0.42, blue: 0.71),
                     end:   Color(red: 1.00, green: 0.71, blue: 0.42),
                     accent: Color(red: 0.78, green: 0.20, blue: 0.45),
                     paletteIndex: 11), // pink/peach
    ]
}
