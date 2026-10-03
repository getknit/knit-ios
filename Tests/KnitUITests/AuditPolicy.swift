import XCTest

/// What the audit reports that is not a defect, each for its reason (ADR 2026-09.jcdx):
///
/// - The Dynamic Type check is never asked for: it resizes in place and loses whatever scrolls away in a lazy list or
///   stack, and toolbar items, which the Large Content Viewer serves. The largest-size walk checks the sizes instead.
/// - Contrast on a control that is off: WCAG 1.4.3 exempts inactive components, Save with nothing to save among them.
/// - Anything in or under a navigation bar, a sheet's included: content scrolled beneath one is read through its
///   glass, as are its glass buttons (Done reads 6:1 in its own screenshot), and its text is capped by the system,
///   which shows it whole in the Large Content Viewer. The glass runs up from the bar to the top of the screen, under
///   the status bar too. Text scrolled wholly into that strip is a blur the audit cannot name an element for, so a
///   contrast report with no element is exempt while content text lies under the glass.
/// - Contrast of anything not wholly on screen: the part off it is read as black.
/// - Contrast that the element's own pixels pass: the audit fails the newest message of a thread at the largest
///   size, black on light gray, whatever the view does. Its screenshot is measured instead, darkest pixel against
///   lightest, which is the text against what it sits on, and it must reach WCAG's 4.5:1.
/// - Clipping of text, buttons and fields: the check calls wrapped text clipped (the status line it flags reads whole at
///   the largest size), a button's label wraps the same way (Clear verification, flagged at the default size, reads
///   whole on two lines at the largest), and a one-line field scrolls rather than loses its text. No view limits its
///   lines but the chat list's preview, and the largest-size walk's screenshots show the rest. Text combined into one
///   element, which the report names no element for, is text all the same.
@MainActor
enum AuditPolicy {
    /// Whether `issue`, found in `app`, is one of the reports above. `bars` are the navigation bars' frames, `window`
    /// the screen's.
    static func exempt(_ issue: XCUIAccessibilityAuditIssue, in app: XCUIApplication, bars: [CGRect], window: CGRect) -> Bool {
        let glass = bars.map { CGRect(x: $0.minX, y: window.minY, width: $0.width, height: $0.maxY - window.minY) }
        guard let element = issue.element else {
            switch issue.auditType {
            case .textClipped:
                return true
            case .contrast:
                return textUnderGlass(in: app, bars: bars, glass: glass)
            default:
                return false
            }
        }
        let frame = element.frame
        if glass.contains(where: { $0.intersects(frame) }) {
            return true
        }
        switch issue.auditType {
        case .contrast:
            return !element.isEnabled || !window.contains(frame) || measuredContrast(of: element) >= minimumContrast
        case .textClipped:
            return [.staticText, .button, .textField].contains(element.elementType)
        default:
            return false
        }
    }

    /// Whether any content text shows only under the glass: some of it in the strip above a bar, none of it below the
    /// bar. A bar's own title and back button sit wholly in the bar, so they never count.
    private static func textUnderGlass(in app: XCUIApplication, bars: [CGRect], glass: [CGRect]) -> Bool {
        app.staticTexts.allElementsBoundByIndex.contains { text in
            let frame = text.frame
            return zip(bars, glass).contains { bar, glass in
                frame.minY < bar.minY && glass.intersects(frame) && frame.maxY <= glass.maxY
            }
        }
    }

    /// WCAG AA's contrast for text of normal size.
    private static let minimumContrast = 4.5

    /// The contrast of `element`'s screenshot: its lightest pixel's relative luminance against its darkest's, by WCAG's
    /// formula. Zero when the screenshot cannot be read, which never exempts anything.
    private static func measuredContrast(of element: XCUIElement) -> Double {
        guard let image = element.screenshot().image.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            return 0
        }
        let (width, height) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
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
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            return 0
        }
        var darkest = 1.0
        var lightest = 0.0
        for start in stride(from: 0, to: pixels.count, by: 4) {
            let value = luminance(pixels[start], pixels[start + 1], pixels[start + 2])
            darkest = min(darkest, value)
            lightest = max(lightest, value)
        }
        return (lightest + 0.05) / (darkest + 0.05)
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
