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
/// - Contrast of a thread's text under the bar below it, while the thread is scrolled up, which the way back to the newest
///   message marks: content scrolled beneath the composer is read through its glass, as under a navigation bar. A thread
///   resting on its bottom edge has nothing under the bar, so text found there still fails, and the bar's own words stay
///   checked.
/// - Contrast reported for no element while every text on screen passes the rules here: a thread's rows are SwiftUI in
///   UIKit cells (ADR 2026-10.pkbu), and the audit names no element for some of their text, a reaction chip's emoji or
///   words under the composer's glass among it. Each text is then checked as if the report had named it, its own pixels
///   measured where no rule exempts it, so text that fails still fails.
/// - Contrast of an emoji, an element whose label is one: a picture the font draws in its own colors, which no view picks.
///   A reaction chip's 👍 is yellow on light gray, and no fill brings it to 4.5:1 in light and dark alike. WCAG 1.4.3 is
///   for text; the chip's count and the bubble's VoiceOver value carry what it says (ADR 2026-10.ehe6).
/// - Contrast that the element's own pixels pass: the audit fails the newest message of a thread at the largest
///   size, black on light gray, whatever the view does. Its screenshot is measured instead, darkest pixel against
///   lightest, which is the text against what it sits on, and it must reach WCAG's 4.5:1.
/// - The clipping check is never asked for either. It called wrapped text clipped (the status line it flagged reads whole
///   at the largest size), and a wrapped button label and a one-line field the same way, so text, buttons and fields
///   were exempt from it already. What it still cost: run with contrast, it never finished over a truncated navigation
///   title on glass, and to reach every cell it scrolls each collection view, which leaves a thread off its bottom edge.
///   No view limits its lines but the chat list's preview, and the largest-size walk's screenshots show the rest.
/// - Text read through an alert: a modal alert takes the screen from VoiceOver, so what lies behind it leaves the
///   accessibility tree, and the alert's glass shows that text through and at its edges. The audit reports it as text no
///   element names. Such a report is exempt only while an alert is up with content text partly under it; the alert's
///   own words are elements, which the other checks read.
/// - A missing description on the keyboard's suggestion cells: the system draws the bar above its keys, empty until it has
///   something to suggest, and an empty cell has nothing to say. The report names the cell's class, `TUIPredictionViewCell`,
///   and only a report that does is exempt; every element Knit draws is still read.
@MainActor
enum AuditPolicy {
    /// What one screen's audit asks for: every check but Dynamic Type and clipping, for the reasons above.
    static let checks = XCUIAccessibilityAuditType.all.subtracting([.dynamicType, .textClipped])

    /// Whether `issue`, found in `app`, is one of the reports above. `bars` are the navigation bars' frames, `window`
    /// the screen's.
    static func exempt(_ issue: XCUIAccessibilityAuditIssue, in app: XCUIApplication, bars: [CGRect], window: CGRect) -> Bool {
        let glass = bars.map { CGRect(x: $0.minX, y: window.minY, width: $0.width, height: $0.maxY - window.minY) }
        guard let element = issue.element else {
            switch issue.auditType {
            case .contrast:
                return textUnderGlass(in: app, bars: bars, glass: glass) || noTextFails(in: app, glass: glass, window: window)
            case .elementDetection:
                return textBehindAlert(in: app)
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
            return passesContrast(element, in: app, window: window)
        case .sufficientElementDescription:
            return issue.detailedDescription.contains("TUIPredictionViewCell")
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

    /// Whether `element` is a thread's text reaching under the bar below it, none of the bar's own words, while the way back
    /// to the newest message shows.
    private static func isUnderTheThreadsBar(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let bar = app.element(AccessibilityID.chatBottomBar)
        guard element.elementType == .staticText, app.element(AccessibilityID.chatScrollToNewest).exists, bar.exists else {
            return false
        }
        let frame = element.frame
        return frame.maxY > bar.frame.minY
            && !bar.staticTexts.allElementsBoundByIndex.contains { $0.frame == frame && $0.label == element.label }
    }

    /// Whether `element`, out from under the glass, passes contrast by the rules above.
    private static func passesContrast(_ element: XCUIElement, in app: XCUIApplication, window: CGRect) -> Bool {
        !element.isEnabled || !window.contains(element.frame) || isEmoji(element.label) || isUnderTheThreadsBar(element, in: app)
            || measuredContrast(of: element) >= minimumContrast
    }

    /// Whether every text on screen passes contrast by the rules above, so a report that names no element is about none
    /// of them.
    private static func noTextFails(in app: XCUIApplication, glass: [CGRect], window: CGRect) -> Bool {
        app.staticTexts.allElementsBoundByIndex.allSatisfy { text in
            glass.contains { $0.intersects(text.frame) } || passesContrast(text, in: app, window: window)
        }
    }

    /// Whether an alert is up with some content text partly under it, which its glass shows through.
    private static func textBehindAlert(in app: XCUIApplication) -> Bool {
        let alert = app.alerts.firstMatch
        guard alert.exists else {
            return false
        }
        let frame = alert.frame
        return app.staticTexts.allElementsBoundByIndex.contains { text in
            text.frame.intersects(frame) && !frame.contains(text.frame)
        }
    }

    /// Whether `label` is one emoji: one character whose first scalar shows as an emoji, or is made one by what follows
    /// it, as ❤️ is. A bare digit or symbol that defaults to text is no emoji.
    private static func isEmoji(_ label: String) -> Bool {
        guard label.count == 1, let first = label.unicodeScalars.first else {
            return false
        }
        return first.properties.isEmojiPresentation || (first.properties.isEmoji && label.unicodeScalars.count > 1)
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
