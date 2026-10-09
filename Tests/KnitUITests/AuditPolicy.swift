import XCTest

/// What the audit leaves out, and what it reports that is not a defect, each for its reason (ADR 2026-09.jcdx):
///
/// - The Dynamic Type check is never asked for: it resizes in place and loses whatever scrolls away in a lazy list or
///   stack, and toolbar items, which the Large Content Viewer serves. The largest-size walk checks the sizes instead.
/// - The clipping check is never asked for either. It called wrapped text clipped (the status line it flagged reads whole
///   at the largest size), and a wrapped button label and a one-line field the same way, so text, buttons and fields
///   were exempt from it already. What it still cost: run with contrast, it never finished over a truncated navigation
///   title on glass, and to reach every cell it scrolls each collection view, which leaves a thread off its bottom edge.
///   No view limits its lines but the chat list's preview, and the largest-size walk's screenshots show the rest.
/// - The contrast check is Knit's own, not the audit's. The audit's counts an element's colors one object a pixel, and over
///   saturated content blurred under Liquid Glass it never finished inside its 15 seconds, after which every audit in that
///   Simulator timed out behind it. Every element on screen with a label is measured instead, from one screenshot: its
///   lightest pixel against its darkest, which is its text or glyph against what it sits on, and it must reach WCAG's 4.5:1.
///   It skips:
///   - a control that is off: WCAG 1.4.3 exempts inactive components, Save with nothing to save among them;
///   - anything in or under a navigation bar, a sheet's included: content scrolled beneath one is read through its glass,
///     and the bar's own text is capped by the system, which shows it whole in the Large Content Viewer. The glass runs up
///     from the bar to the top of the screen, under the status bar too;
///   - anything not wholly on screen;
///   - a thread's text under the bar below it, while the thread is scrolled up, which the way back to the newest message
///     marks: content scrolled beneath the composer is read through its glass, as under a navigation bar. A thread resting
///     on its bottom edge has nothing under the bar, so text found there still fails, and the bar's own words stay
///     checked;
///   - an emoji, an element whose label is one: a picture the font draws in its own colors, which no view picks. A
///     reaction chip's 👍 is yellow on light gray, and no fill brings it to 4.5:1 in light and dark alike. WCAG 1.4.3 is
///     for text; the chip's count and the bubble's VoiceOver value carry what it says (ADR 2026-10.ehe6);
///   - an element with no label, which has nothing to read and which the description check reports, and a text field,
///     whose placeholder WCAG does not hold to 4.5:1;
///   - the system's own chrome, named by its label: scroll indicators, the keyboard's suggestion bar and a sheet's grabber,
///     each faint on purpose and colored by no view of Knit's;
///   - text inside a system alert, which draws its message in its own secondary color on its own glass, and a message's
///     menu, a context menu the system draws on its own material, Delete in its destructive red (4.4:1 on that material).
/// - Text read through an alert: a modal alert takes the screen from VoiceOver, so what lies behind it leaves the
///   accessibility tree, and the alert's glass shows that text through and at its edges. The audit reports it as text no
///   element names. Such a report is exempt only while an alert is up with content text partly under it; the alert's
///   own words are elements, which the other checks read.
/// - A missing description on the keyboard's suggestion cells: the system draws the bar above its keys, empty until it has
///   something to suggest, and an empty cell has nothing to say. The report names the cell's class, `TUIPredictionViewCell`,
///   and only a report that does is exempt; every element Knit draws is still read.
@MainActor
enum AuditPolicy {
    /// What one screen's audit asks for: every check but Dynamic Type, clipping and contrast, for the reasons above.
    static let checks = XCUIAccessibilityAuditType.all.subtracting([.dynamicType, .textClipped, .contrast])

    /// One element whose contrast fails: what it is, and how it looks.
    struct ContrastFailure {
        let description: String
        let image: UIImage?
    }

    /// Whether `issue`, found in `app`, is one of the reports above. `bars` are the navigation bars' frames, `window`
    /// the screen's.
    static func exempt(_ issue: XCUIAccessibilityAuditIssue, in app: XCUIApplication, bars: [CGRect], window: CGRect) -> Bool {
        guard let element = issue.element else {
            return issue.auditType == .elementDetection && textBehindAlert(in: app)
        }
        if glass(bars, window: window).contains(where: { $0.intersects(element.frame) }) {
            return true
        }
        return issue.auditType == .sufficientElementDescription && issue.detailedDescription.contains("TUIPredictionViewCell")
    }

    /// Every element on `app`'s screen whose contrast fails by the rules above, read from one snapshot of its elements and
    /// one screenshot, so a screen of rows takes two round trips rather than a few for each row.
    static func contrastFailures(in app: XCUIApplication, bars: [CGRect], window: CGRect) throws -> [ContrastFailure] {
        let elements = flattened(try app.snapshot())
        guard let pixels = ScreenPixels(app.screenshot(), window: window) else {
            return [ContrastFailure(description: "the screenshot could not be read", image: nil)]
        }
        let glass = glass(bars, window: window)
        let underBar = threadsBar(in: elements)
        let alerts = elements.filter { $0.elementType == .alert }.map(\.frame)
        return elements.compactMap { element in
            let frame = element.frame
            let skipped =
                !measured.contains(element.elementType) || element.label.isEmpty || !element.isEnabled || !window.contains(frame)
                || frame.isEmpty || glass.contains { $0.intersects(frame) } || isEmoji(element.label)
                || underBar?(element) == true || alerts.contains { $0.contains(frame) } || isChrome(element.label)
                || menuItems.contains(element.identifier)
            guard !skipped else {
                return nil
            }
            let ratio = pixels.contrast(in: frame)
            guard ratio < minimumContrast else {
                return nil
            }
            let measure = String(format: "%.2f:1, under %.1f:1", ratio, minimumContrast)
            return ContrastFailure(
                description: "Contrast failed: \(element.elementType.rawValue) '\(element.label)' #\(element.identifier) at \(frame). "
                    + measure,
                image: pixels.image(of: frame)
            )
        }
    }

    /// What the contrast check reads: whatever shows text or a glyph. A text field is left out for its placeholder, and
    /// an image for a photo, which says nothing in its own pixels.
    private static let measured: Set<XCUIElement.ElementType> = [.staticText, .button, .link, .cell, .other, .textView, .toggle]

    /// Whether an element is a thread's text under the bar below it, none of the bar's own words, while the way back to the
    /// newest message shows; `nil` when no such bar shows.
    private static func threadsBar(in elements: [any XCUIElementSnapshot]) -> ((any XCUIElementSnapshot) -> Bool)? {
        guard let bar = elements.first(where: { $0.identifier == AccessibilityID.chatBottomBar }),
            elements.contains(where: { $0.identifier == AccessibilityID.chatScrollToNewest })
        else {
            return nil
        }
        let own = Set(flattened(bar).filter { $0.elementType == .staticText }.map { "\($0.frame)" })
        return { element in
            element.elementType == .staticText && element.frame.maxY > bar.frame.minY && !own.contains("\(element.frame)")
        }
    }

    /// A message's menu: the system draws it as a context menu, on its own material and in its own colors, Delete in its
    /// destructive red.
    private static let menuItems: Set = [
        AccessibilityID.chatMessageCopy, AccessibilityID.chatMessageDelete, AccessibilityID.chatMessageReport,
    ]

    /// Whether `label` names a piece of the system's own chrome: a scroll indicator, the keyboard's suggestion bar, or a
    /// sheet's grabber. Each draws itself faint on purpose, and no view of Knit's picks its colors.
    private static func isChrome(_ label: String) -> Bool {
        ["Vertical scroll bar", "Horizontal scroll bar", "Typing Predictions", "Sheet Grabber"].contains { label.hasPrefix($0) }
    }

    /// The glass over the screen's top: each bar's width, from the window's top edge down to the bar's bottom.
    private static func glass(_ bars: [CGRect], window: CGRect) -> [CGRect] {
        bars.map { CGRect(x: $0.minX, y: window.minY, width: $0.width, height: $0.maxY - window.minY) }
    }

    /// `snapshot` and everything under it.
    private static func flattened(_ snapshot: any XCUIElementSnapshot) -> [any XCUIElementSnapshot] {
        [snapshot] + snapshot.children.flatMap(flattened)
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
}
