import SwiftUI

/// Reusable card row used by ConnectSheet's three method choices
/// (Show my QR / Scan / Paste). Icon + title + dim-parens technical term +
/// descriptive subtitle + trailing chevron. Tap fires the closure.
///
/// Per design-system.md: no Color(.systemGray6) wrapper, theme-friendly
/// colors, tap target = entire row.
struct ConnectMethodCard: View {
    let iconSystemName: String
    let iconGradient: LinearGradient
    let title: String
    let term: String?           // dim-parens technical term, e.g. "(bunker)"
    let subtitle: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(iconGradient)
                    Image(systemName: iconSystemName)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                        if let term {
                            Text(term)
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
