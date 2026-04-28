import SwiftUI

struct AvatarView: View {
    let pubkeyHex: String
    /// Optional human-readable name. When non-empty, the first 1-2 letters of
    /// the name are shown instead of the first two hex chars of the pubkey.
    /// The gradient stays pubkey-derived so renames don't change the color.
    var name: String? = nil
    var size: CGFloat = 48

    private var gradient: LinearGradient {
        let bytes = Array(pubkeyHex.prefix(12))
        let hue1 = Double(hexValue(bytes, offset: 0)) / 255.0
        let hue2 = Double(hexValue(bytes, offset: 4)) / 255.0
        return LinearGradient(
            colors: [
                Color(hue: hue1, saturation: 0.7, brightness: 0.9),
                Color(hue: hue2, saturation: 0.6, brightness: 0.7)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Up to two letters. Prefers initials of the first two whitespace-
    /// separated words of `name` (e.g. "Joe Bloggs" → "JB"), falls back to
    /// the first two letters of a single-word name, then to the pubkey
    /// prefix if name is nil/blank.
    private var initials: String {
        if let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            let words = trimmed.split(whereSeparator: { $0.isWhitespace })
            if words.count >= 2,
               let first = words[0].first,
               let second = words[1].first {
                return String([first, second]).uppercased()
            }
            return String(trimmed.prefix(2)).uppercased()
        }
        return String(pubkeyHex.prefix(2)).uppercased()
    }

    /// Use a monospaced design only for the pubkey-prefix fallback (which is
    /// hex characters); proportional for actual name initials.
    private var initialsFont: Font {
        let isPubkeyFallback = (name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return isPubkeyFallback
            ? .system(size: size * 0.35, weight: .bold, design: .monospaced)
            : .system(size: size * 0.4, weight: .bold)
    }

    var body: some View {
        Circle()
            .fill(gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(initialsFont)
                    .foregroundStyle(.white)
            }
    }

    private func hexValue(_ chars: [Character], offset: Int) -> UInt8 {
        guard offset + 1 < chars.count else { return 128 }
        let hex = String(chars[offset]) + String(chars[offset + 1])
        return UInt8(hex, radix: 16) ?? 128
    }
}
