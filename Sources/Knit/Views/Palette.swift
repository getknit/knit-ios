#if os(iOS)
    import KnitAppCore
    import SwiftUI
    import UIKit

    /// The app's colors, from KnitAppCore's ``Swatches``, where `SwatchContrastTests` holds each text color to 4.5:1 or more
    /// against every surface it sits on in light and dark (WCAG AA, and what `performAccessibilityAudit` holds MVP screens
    /// to), and to 7:1 with Increase Contrast on. The tint is Knit's coral (ADR 2026-10.5waw). The system's secondary gray
    /// reads 2.8 to 3.4:1 on grouped backgrounds, so it is not used for text. Defined in code rather than the asset
    /// catalog, which only the Xcode project compiles.
    internal enum Palette {
        /// The tint: buttons, links, a group's author names, the delivered tick.
        static let accent = dynamic(Swatches.accent)
        /// A label on an ``accent`` fill: white in light, black in dark, where the accent is too light for white.
        static let onAccent = dynamic(Swatches.onAccent)
        /// Secondary text: previews, footers, times.
        static let secondaryText = dynamic(Swatches.secondaryText)
        /// In range, allowed.
        static let positive = dynamic(Swatches.positive)
        /// Something the radio cannot do.
        static let warning = dynamic(Swatches.warning)
        /// Over a limit, and the label of an action that removes something: the system's red reads about 3.6:1 on a
        /// grouped cell in light.
        static let critical = dynamic(Swatches.critical)
        /// Our own bubble: solid coral, as Signal fills its own with its blue.
        static let ownBubble = dynamic(Swatches.ownBubble)
        /// The words on ``ownBubble``.
        static let onOwnBubble = dynamic(Swatches.onOwnBubble)
        /// Someone else's bubble: an opaque gray, so the words on it measure against it and not the thread behind.
        static let incomingBubble = dynamic(Swatches.incomingBubble)
        /// A name a message mentions, in someone else's bubble (ADR 2026-10.nbhj).
        static let mention = dynamic(Swatches.mention)
        /// A verify code's paper: white in dark mode too (ADR 2026-10.65xx).
        static let codePaper = Color(uiColor: rgb(Swatches.codePaper))
        /// The capsule a line sits in over a photo in the viewer, under white text, which reads 14:1 on it whatever the
        /// photo shows.
        static let viewerCaption = Color(uiColor: rgb(Swatches.viewerCaption))

        /// The room's face: Knit's mark on our bubble's coral (`ic_knit_room` in knit-next).
        static let roomTint = (container: ownBubble, onContainer: onOwnBubble)

        /// The disc and the initial of a face without a photo, by its slot (``AvatarTint/slot(for:)``), in light and dark.
        static func avatarTint(_ slot: Int) -> (container: Color, onContainer: Color) {
            avatarTints[min(max(slot, 0), avatarTints.count - 1)]
        }

        /// ``AvatarTint``'s two palettes, slot by slot. An identity's color never follows anything else on the phone,
        /// so a person is the same hue on every phone that knows them (ADR 2026-09.j8c7 in knit-next).
        private static let avatarTints = zip(AvatarTint.light, AvatarTint.dark).map { light, dark in
            (
                container: dynamic(Swatch(light: light.container, dark: dark.container)),
                onContainer: dynamic(Swatch(light: light.onContainer, dark: dark.onContainer))
            )
        }

        private static let channelMax: CGFloat = 255
        private static let byte = 0xFF
        private static let redShift = 16
        private static let greenShift = 8

        /// `swatch` as the screen draws it now: light or dark, with Increase Contrast on or off.
        private static func dynamic(_ swatch: Swatch) -> Color {
            Color(
                uiColor: UIColor { traits in
                    rgb(swatch.value(dark: traits.userInterfaceStyle == .dark, increased: traits.accessibilityContrast == .high))
                }
            )
        }

        private static func rgb(_ hex: Int) -> UIColor {
            let channel = { (shift: Int) in CGFloat((hex >> shift) & byte) / channelMax }
            return UIColor(red: channel(redShift), green: channel(greenShift), blue: channel(0), alpha: 1)
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

    /// A row's words after a glyph, as Signal's settings rows have them (ADR 2026-10.5waw); at the accessibility sizes the
    /// words alone, which the glyph would squeeze until they broke.
    internal struct RowLabel: View {
        let title: String
        let symbol: String
        @Environment(\.dynamicTypeSize) private var typeSize

        init(_ title: String, symbol: String) {
            self.title = title
            self.symbol = symbol
        }

        var body: some View {
            if typeSize.isAccessibilitySize {
                Text(title)
            } else {
                Label(title, systemImage: symbol)
            }
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
