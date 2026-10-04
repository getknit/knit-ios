import Foundation
import KnitAppCore
import Testing

/// Every color the app draws text in, measured against what it sits on, in light and dark and with Increase Contrast on
/// (ADR 2026-10.5waw). WCAG AA asks 4.5:1 of text, which is what the accessibility audit holds screens to (ADR
/// 2026-09.jcdx); with Increase Contrast on, the swatches reach AAA's 7:1. The audit measures pixels on one Simulator
/// in light mode; this measures every swatch on every surface, on Linux, before a view draws one.
@Suite struct SwatchContrastTests {
    /// The system's surfaces that text sits on. In light: white (`systemBackground`, a grouped cell) and `#F2F2F7` (a
    /// grouped list's background, `secondarySystemBackground`). In dark: black, `#1C1C1E` (a cell, a sheet) and `#2C2C2E`
    /// (a cell in a sheet).
    private static let surfaces = (light: [0xFFFFFF, 0xF2F2F7], dark: [0x000000, 0x1C1C1E, 0x2C2C2E])
    /// The system's label color, which a bubble's words take unless the bubble is ours.
    private static let systemLabel = Swatch(light: 0x000000, dark: 0xFFFFFF)
    /// WCAG AA for text.
    private static let text = 4.5
    /// WCAG AAA for text, which Increase Contrast reaches.
    private static let increasedText = 7.0

    /// The colors views set text and glyphs in, each over every surface.
    private static let textColors: [(String, Swatch)] = [
        ("accent", Swatches.accent),
        ("secondaryText", Swatches.secondaryText),
        ("positive", Swatches.positive),
        ("warning", Swatches.warning),
        ("critical", Swatches.critical),
    ]

    /// A text color, and a fill it sits on that is not a system surface.
    private struct Pair {
        let name: String
        let label: Swatch
        let fill: Swatch
    }

    private static let pairs = [
        Pair(name: "onAccent on accent", label: Swatches.onAccent, fill: Swatches.accent),
        Pair(name: "onOwnBubble on ownBubble", label: Swatches.onOwnBubble, fill: Swatches.ownBubble),
        Pair(name: "label on incomingBubble", label: systemLabel, fill: Swatches.incomingBubble),
        Pair(name: "secondaryText on incomingBubble", label: Swatches.secondaryText, fill: Swatches.incomingBubble),
    ]

    /// The four ways a screen draws: light or dark, with Increase Contrast off or on.
    private static let modes = [(false, false), (true, false), (false, true), (true, true)]

    @Test func everyTextColorReadsOnEverySystemSurface() {
        for (name, swatch) in Self.textColors {
            for (dark, increased) in Self.modes {
                for surface in dark ? Self.surfaces.dark : Self.surfaces.light {
                    let ratio = WCAG.contrast(swatch.value(dark: dark, increased: increased), surface)
                    #expect(ratio >= Self.floor(increased), "\(name) is \(ratio):1 on \(hex(surface)), \(Self.mode(dark, increased))")
                }
            }
        }
    }

    @Test func everyLabelReadsOnItsFill() {
        for pair in Self.pairs {
            for (dark, increased) in Self.modes {
                let ratio = WCAG.contrast(
                    pair.label.value(dark: dark, increased: increased), pair.fill.value(dark: dark, increased: increased))
                #expect(ratio >= Self.floor(increased), "\(pair.name) is \(ratio):1, \(Self.mode(dark, increased))")
            }
        }
    }

    /// The viewer's caption reads in white over any photo, and a verify code is black on white.
    @Test func theViewersCaptionAndTheCodesPaperRead() {
        #expect(WCAG.contrast(0xFFFFFF, Swatches.viewerCaption) >= Self.increasedText)
        #expect(WCAG.contrast(0x000000, Swatches.codePaper) >= Self.increasedText)
    }

    /// The coral is Android's, deepened: the brand's own `#E55E4C` reads only 3.5:1 under white, too faint for a label.
    @Test func theTintIsAndroidsCoralDeepenedToRead() {
        #expect(WCAG.contrast(0xFFFFFF, 0xE55E4C) < Self.text)
        #expect(Swatches.accent.light == 0xBD4030, "Android's light primary, `Color.kt`")
        #expect(Swatches.ownBubble.light == Swatches.accent.light, "our bubble is the tint in light")
    }

    /// A swatch with no Increase Contrast values keeps its own, and each mode reads its value.
    @Test func aSwatchReadsItsValueForEachMode() {
        let plain = Swatch(light: 1, dark: 2)
        #expect(plain.increasedLight == 1 && plain.increasedDark == 2)
        let full = Swatch(light: 1, dark: 2, increasedLight: 3, increasedDark: 4)
        #expect(Self.modes.map { full.value(dark: $0.0, increased: $0.1) } == [1, 2, 3, 4])
    }

    private static func floor(_ increased: Bool) -> Double {
        increased ? increasedText : text
    }

    private static func mode(_ dark: Bool, _ increased: Bool) -> String {
        (dark ? "dark" : "light") + (increased ? ", Increase Contrast" : "")
    }
}

/// `value` as `#RRGGBB`, for a failure's message.
private func hex(_ value: Int) -> String {
    String(format: "#%06X", value)
}
