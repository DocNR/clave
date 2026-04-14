import SwiftUI

struct AvatarView: View {
    let pubkeyHex: String
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

    var body: some View {
        Circle()
            .fill(gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(String(pubkeyHex.prefix(2)).uppercased())
                    .font(.system(size: size * 0.35, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            }
    }

    private func hexValue(_ chars: [Character], offset: Int) -> UInt8 {
        guard offset + 1 < chars.count else { return 128 }
        let hex = String(chars[offset]) + String(chars[offset + 1])
        return UInt8(hex, radix: 16) ?? 128
    }
}
