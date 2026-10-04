import Foundation

/// WCAG's contrast ratio between two sRGB colors, as knit-next's `ColorSchemeTest.contrastRatio` measures it.
internal enum WCAG {
    /// The red, green and blue of `hex`, each from 0 to 1.
    static func channels(_ hex: Int) -> [Double] {
        [16, 8, 0].map { Double((hex >> $0) & 0xFF) / 255 }
    }

    /// The ratio between `first` and `second`, from 1 to 21, whichever is lighter.
    static func contrast(_ first: Int, _ second: Int) -> Double {
        let luminance = { (hex: Int) -> Double in
            let linear = channels(hex).map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }
        let (high, low) = (max(luminance(first), luminance(second)), min(luminance(first), luminance(second)))
        return (high + 0.05) / (low + 0.05)
    }
}
