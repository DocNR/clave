import SwiftUI
import CryptoKit

/// Deterministic gradient palette for per-account visual identity.
///
/// Pubkey hex → SHA-256 → first 2 bytes → palette index. Same account
/// always gets the same gradient across launches and devices.
///
/// Used by AccountStripView (active pill ring), HomeView (full-screen ambient
/// gradient + Pair New Connection icon), AccountDetailView (gradient banner
/// header), ApprovalSheet (SigningAsHeader tint).
///
/// Palette is curated to avoid clashy hues, low-contrast pairs, and yellows
/// that look broken on white backgrounds. 12 entries — comfortably more than
/// the 5-account pairing cap, low collision probability for typical use.
///
/// Equatable conformance is synthesized from the stored properties (Color is
/// Equatable on iOS 17+); relied on by `AccountThemeTests`.
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
        guard normalized.count == 64,
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
    /// indicators. Indices are stable: never reorder, AND never insert
    /// mid-array and renumber — both would reassign every existing account's
    /// color across launches. Append-only at the end is safe.
    static let palette: [AccountTheme] = [
        AccountTheme(start: Color(red: 0.48, green: 0.55, blue: 1.00),
                     end:   Color(red: 0.85, green: 0.25, blue: 0.95),
                     accent: Color(red: 0.35, green: 0.18, blue: 1.00),
                     paletteIndex: 0),  // blue → fuchsia
        AccountTheme(start: Color(red: 0.00, green: 0.78, blue: 1.00),
                     end:   Color(red: 0.10, green: 0.35, blue: 0.85),
                     accent: Color(red: 0.00, green: 0.35, blue: 0.40),
                     paletteIndex: 1),  // cyan → deep blue
        AccountTheme(start: Color(red: 1.00, green: 0.55, blue: 0.29),
                     end:   Color(red: 0.95, green: 0.20, blue: 0.30),
                     accent: Color(red: 0.78, green: 0.35, blue: 0.00),
                     paletteIndex: 2),  // orange → red
        AccountTheme(start: Color(red: 1.00, green: 0.29, blue: 0.55),
                     end:   Color(red: 0.65, green: 0.18, blue: 0.78),
                     accent: Color(red: 0.78, green: 0.10, blue: 0.40),
                     paletteIndex: 3),  // pink → purple
        AccountTheme(start: Color(red: 0.29, green: 0.64, blue: 1.00),
                     end:   Color(red: 0.10, green: 0.30, blue: 0.70),
                     accent: Color(red: 0.10, green: 0.45, blue: 0.85),
                     paletteIndex: 4),  // sky → navy
        AccountTheme(start: Color(red: 0.29, green: 1.00, blue: 0.55),
                     end:   Color(red: 0.10, green: 0.65, blue: 0.85),
                     accent: Color(red: 0.10, green: 0.55, blue: 0.20),
                     paletteIndex: 5),  // mint → teal
        AccountTheme(start: Color(red: 1.00, green: 0.42, blue: 0.42),
                     end:   Color(red: 0.85, green: 0.20, blue: 0.55),
                     accent: Color(red: 0.78, green: 0.18, blue: 0.18),
                     paletteIndex: 6),  // red → magenta
        AccountTheme(start: Color(red: 0.55, green: 0.29, blue: 1.00),
                     end:   Color(red: 0.93, green: 0.42, blue: 1.00),
                     accent: Color(red: 0.40, green: 0.10, blue: 0.78),
                     paletteIndex: 7),  // violet/fuchsia (kept — already strong)
        AccountTheme(start: Color(red: 0.10, green: 0.78, blue: 0.60),
                     end:   Color(red: 0.05, green: 0.40, blue: 0.55),
                     accent: Color(red: 0.05, green: 0.40, blue: 0.30),
                     paletteIndex: 8),  // emerald → deep teal
        AccountTheme(start: Color(red: 0.78, green: 0.42, blue: 0.93),
                     end:   Color(red: 1.00, green: 0.55, blue: 0.78),
                     accent: Color(red: 0.55, green: 0.18, blue: 0.71),
                     paletteIndex: 9),  // orchid → pink (kept — already medium)
        AccountTheme(start: Color(red: 0.29, green: 0.42, blue: 0.85),
                     end:   Color(red: 0.55, green: 0.71, blue: 1.00),
                     accent: Color(red: 0.10, green: 0.20, blue: 0.65),
                     paletteIndex: 10), // navy → light blue (kept — already medium)
        AccountTheme(start: Color(red: 1.00, green: 0.42, blue: 0.71),
                     end:   Color(red: 1.00, green: 0.71, blue: 0.42),
                     accent: Color(red: 0.78, green: 0.20, blue: 0.45),
                     paletteIndex: 11), // pink → peach (kept — already strong)
    ]
}
