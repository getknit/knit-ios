#if os(iOS)
    import KnitAppCore
    import SwiftUI
    import UIKit

    /// The app's colors, each at least 4.5:1 against every surface it sits on, in light and dark (WCAG AA for text,
    /// and what `performAccessibilityAudit` holds MVP screens to). The system's secondary gray reads 2.8 to 3.4:1 on
    /// grouped backgrounds, and white on the default blue 4.0:1, so neither is used for text. Defined in code rather than
    /// the asset catalog, which only the Xcode project compiles.
    internal enum Palette {
        /// The tint: buttons, links, the own bubble. 6.2:1 under white text and 5.1:1 or more as text in light; 5.3:1 or
        /// more as text on dark surfaces, where a filled button takes ``onAccent`` for its label.
        static let accent = dynamic(Swatch.accent)
        /// A label on an ``accent`` fill: white in light, black in dark, where the accent is too light for white.
        static let onAccent = dynamic(Swatch.onAccent)
        /// Secondary text: previews, footers, times. 5.3:1 or more in light, 5.1:1 or more in dark.
        static let secondaryText = dynamic(Swatch.secondaryText)
        /// In range, allowed.
        static let positive = dynamic(Swatch.positive)
        /// Something the radio cannot do.
        static let warning = dynamic(Swatch.warning)
        /// Over a limit, and the label of an action that removes something: the system's red reads about 3.6:1 on a
        /// grouped cell in light.
        static let critical = dynamic(Swatch.critical)
        /// A verify code's paper: white in dark mode too, because the code is drawn black on white, and many readers, zxing
        /// among them, read no inverted code (ADR 2026-10.65xx).
        static let codePaper = Color(uiColor: rgb(Swatch.codePaper))

        /// The room's face: the accent's glyph on a pale wash of it.
        static let roomTint = (container: dynamic(Swatch.roomContainer), onContainer: accent)

        /// The disc and the initial of a face without a photo, by its slot (``AvatarTint/slot(for:)``), in light and dark.
        static func avatarTint(_ slot: Int) -> (container: Color, onContainer: Color) {
            avatarTints[min(max(slot, 0), avatarTints.count - 1)]
        }

        /// ``AvatarTint``'s two palettes, slot by slot. An identity's color never follows anything else on the phone,
        /// so a person is the same hue on every phone that knows them (ADR 2026-09.j8c7 in knit-next).
        private static let avatarTints = zip(AvatarTint.light, AvatarTint.dark).map { light, dark in
            (
                container: dynamic((light: light.container, dark: dark.container)),
                onContainer: dynamic((light: light.onContainer, dark: dark.onContainer))
            )
        }

        /// Each color's sRGB value in light mode and in dark, as `0xRRGGBB`.
        private enum Swatch {
            static let accent = (light: 0x0A5CC7, dark: 0x5AA0FF)
            static let onAccent = (light: 0xFFFFFF, dark: 0x000000)
            static let secondaryText = (light: 0x5E5E63, dark: 0xAEAEB2)
            static let positive = (light: 0x1A7F37, dark: 0x3FB950)
            static let warning = (light: 0xB25000, dark: 0xFFA94D)
            static let critical = (light: 0xC4271C, dark: 0xFF6961)
            static let codePaper = 0xFFFFFF
            static let roomContainer = (light: 0xDCE8F8, dark: 0x1E2A3A)
        }

        private static let channelMax: CGFloat = 255
        private static let byte = 0xFF
        private static let redShift = 16
        private static let greenShift = 8

        private static func dynamic(_ swatch: (light: Int, dark: Int)) -> Color {
            Color(
                uiColor: UIColor { traits in
                    rgb(traits.userInterfaceStyle == .dark ? swatch.dark : swatch.light)
                }
            )
        }

        private static func rgb(_ hex: Int) -> UIColor {
            let channel = { (shift: Int) in CGFloat((hex >> shift) & byte) / channelMax }
            return UIColor(red: channel(redShift), green: channel(greenShift), blue: channel(0), alpha: 1)
        }
    }

    extension View {
        /// A filled, prominent button in the palette's colors: its label stays legible on the accent in dark mode.
        func prominentButton() -> some View {
            buttonStyle(.borderedProminent).foregroundStyle(Palette.onAccent)
        }
    }

    /// A section's header or footer text, in ``Palette/secondaryText``: the system's own gray is too faint on a grouped
    /// background.
    internal struct SectionNote: View {
        let text: String

        init(_ text: String) {
            self.text = text
        }

        var body: some View {
            Text(text).foregroundStyle(Palette.secondaryText)
        }
    }

    /// A label and its value, the value in ``Palette/secondaryText``: `LabeledContent`'s own gray is too faint.
    internal struct ValueRow: View {
        let label: String
        let value: String

        init(_ label: String, value: String) {
            self.label = label
            self.value = value
        }

        var body: some View {
            LabeledContent {
                Text(value).foregroundStyle(Palette.secondaryText)
            } label: {
                Text(label)
            }
        }
    }
#endif
