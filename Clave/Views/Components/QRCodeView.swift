import SwiftUI
import CoreImage.CIFilterBuiltins

struct QRCodeView: View {
    let content: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                qrImage
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 280, height: 280)
                    .padding(16)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                Text("Scan with a NIP-46 compatible client")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .navigationTitle("Bunker QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .snapshotProtected()
    }

    private var qrImage: Image { Self.makeImage(for: content) }

    /// Shared QR image generator. Used by this view and by tab bodies that
    /// embed an inline QR (e.g. ConnectBunkerTabView). Centralizes the
    /// CIFilter pipeline + correction level + fallback image so future
    /// changes happen in one place.
    static func makeImage(for content: String) -> Image {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage,
              let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else {
            return Image(systemName: "xmark.circle")
        }
        return Image(uiImage: UIImage(cgImage: cgImage))
    }
}
