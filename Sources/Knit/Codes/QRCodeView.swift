#if os(iOS)
    import CoreImage
    import CoreImage.CIFilterBuiltins
    import Foundation
    import SwiftUI

    /// A verify code drawn as a QR code (ADR 2026-10.65xx): error correction L, black on white, as Android draws its own
    /// with zxing's defaults (`ui/image/QrCode.kt`). The code is 150 ASCII bytes, which fits a version 7 symbol.
    internal struct QRCodeView: View {
        let text: String
        @State private var image: CGImage?

        var body: some View {
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                } else {
                    Color.clear
                }
            }
            .frame(width: Layout.codeSide, height: Layout.codeSide)
            .padding(Layout.codeQuietZone)
            .background(Palette.codePaper)
            // Black on white under Smart Invert too, as in dark mode: many readers read no inverted code.
            .accessibilityIgnoresInvertColors()
            .task(id: text) { image = Self.render(text) }
        }

        /// The code's modules, one pixel each; the view scales them up without smoothing.
        private static func render(_ text: String) -> CGImage? {
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(text.utf8)
            filter.correctionLevel = "L"
            guard let output = filter.outputImage else {
                return nil
            }
            return CIContext().createCGImage(output, from: output.extent)
        }
    }
#endif
