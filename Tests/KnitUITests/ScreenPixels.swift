import XCTest

/// A screenshot's pixels, read once, so the contrast check measures every element on screen from one picture
/// (`AuditPolicy`, ADR 2026-09.jcdx).
struct ScreenPixels {
    private let image: CGImage
    private let bytes: [UInt8]
    /// Pixels to a point.
    private let scale: CGFloat

    /// `screenshot`'s pixels, for a screen whose window is `window`; `nil` when the picture cannot be read.
    init?(_ screenshot: XCUIScreenshot, window: CGRect) {
        guard let picture = screenshot.image.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB), window.width > 0 else {
            return nil
        }
        let (width, height) = (picture.width, picture.height)
        var read = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = read.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                )
            else {
                return false
            }
            context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            return nil
        }
        image = picture
        bytes = read
        scale = CGFloat(width) / window.width
    }

    /// The contrast inside `frame`, in points: its lightest pixel's relative luminance against its darkest's, by WCAG's
    /// formula. One when `frame` holds no pixel, which never passes.
    func contrast(in frame: CGRect) -> Double {
        guard let pixels = pixels(of: frame) else {
            return 1
        }
        var darkest = 1.0
        var lightest = 0.0
        for row in Int(pixels.minY)..<Int(pixels.maxY) {
            for column in Int(pixels.minX)..<Int(pixels.maxX) {
                let start = (row * image.width + column) * 4
                let value = Self.luminance(bytes[start], bytes[start + 1], bytes[start + 2])
                darkest = min(darkest, value)
                lightest = max(lightest, value)
            }
        }
        return (lightest + 0.05) / (darkest + 0.05)
    }

    /// What `frame` shows, for the report of an element that fails.
    func image(of frame: CGRect) -> UIImage? {
        pixels(of: frame).flatMap { image.cropping(to: $0) }.map { UIImage(cgImage: $0) }
    }

    /// `frame`'s whole pixels, within the picture; `nil` when it holds none.
    private func pixels(of frame: CGRect) -> CGRect? {
        let scaled = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
        let whole = scaled.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return whole.isEmpty ? nil : whole
    }

    /// WCAG's relative luminance of an sRGB pixel.
    private static func luminance(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Double {
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}
