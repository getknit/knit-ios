/// One of the app's colors as sRGB `0xRRGGBB`: in light and dark, and in each with Increase Contrast on.
public struct Swatch: Sendable, Equatable {
    /// The value in light mode.
    public let light: Int
    /// The value in dark mode.
    public let dark: Int
    /// The value in light mode with Increase Contrast on.
    public let increasedLight: Int
    /// The value in dark mode with Increase Contrast on.
    public let increasedDark: Int

    /// A color that is `light` and `dark`, and `increasedLight` and `increasedDark` with Increase Contrast on, or the same
    /// two when those are left out.
    public init(light: Int, dark: Int, increasedLight: Int? = nil, increasedDark: Int? = nil) {
        self.light = light
        self.dark = dark
        self.increasedLight = increasedLight ?? light
        self.increasedDark = increasedDark ?? dark
    }

    /// The value for a screen that is `dark` or not, with Increase Contrast `increased` or not.
    public func value(dark isDark: Bool, increased: Bool) -> Int {
        switch (isDark, increased) {
        case (false, false):
            light
        case (true, false):
            dark
        case (false, true):
            increasedLight
        case (true, true):
            increasedDark
        }
    }
}

/// The app's colors, which `Palette` turns into SwiftUI colors (ADR 2026-10.5waw). They live here, apart from SwiftUI,
/// so `SwatchContrastTests` measures every pair on Linux: each text color at 4.5:1 or more on every system surface it
/// sits on, and 7:1 with Increase Contrast on. The tint is Knit's coral (`Color.kt` in knit-next, its ADR 2026-09.m9h8),
/// deepened from the brand's `#E55E4C`, which reads only 3.5:1 under white text.
public enum Swatches {
    /// The tint: buttons, links, a group's author names, the delivered tick.
    public static let accent = swatch(Base.accent, increased: Increased.accent)
    /// A label on an ``accent`` fill: white in light, black in dark, where the accent is too light for white.
    public static let onAccent = swatch(Base.onAccent)
    /// Secondary text: previews, footers, times.
    public static let secondaryText = swatch(Base.secondaryText, increased: Increased.secondaryText)
    /// In range, allowed: Android's fixed green, which no theme changes.
    public static let positive = swatch(Base.positive, increased: Increased.positive)
    /// Something the radio cannot do.
    public static let warning = swatch(Base.warning, increased: Increased.warning)
    /// Over a limit, and the label of an action that removes something.
    public static let critical = swatch(Base.critical, increased: Increased.critical)
    /// Our own bubble, and the Nearby room's disc: a deeper coral in dark, where white still reads on it.
    public static let ownBubble = swatch(Base.ownBubble, increased: Increased.ownBubble)
    /// The words on ``ownBubble``, and the mark on the room's disc.
    public static let onOwnBubble = swatch(Base.onOwnBubble)
    /// Someone else's bubble, and the capsule a thread's notices sit in, under the label color and ``secondaryText``.
    public static let incomingBubble = swatch(Base.incomingBubble)
    /// A verify code's paper: white in dark mode too, because the code is drawn black on white, and many readers, zxing
    /// among them, read no inverted code (ADR 2026-10.65xx).
    public static let codePaper = 0xFFFFFF
    /// The capsule a line sits in over a photo in the viewer, under white text, whatever the photo shows.
    public static let viewerCaption = 0x2C2C2E

    /// The swatch of `base`, and of `increased` with Increase Contrast on, or of `base` again.
    private static func swatch(_ base: (light: Int, dark: Int), increased: (light: Int, dark: Int)? = nil) -> Swatch {
        Swatch(light: base.light, dark: base.dark, increasedLight: increased?.light, increasedDark: increased?.dark)
    }

    /// Each swatch's values in light and dark.
    private enum Base {
        static let accent = (light: 0xBD4030, dark: 0xFF8A73)
        static let onAccent = (light: 0xFFFFFF, dark: 0x000000)
        static let secondaryText = (light: 0x5E5E63, dark: 0xAEAEB2)
        static let positive = (light: 0x1A7F37, dark: 0x3FB950)
        static let warning = (light: 0xB25000, dark: 0xFFA94D)
        static let critical = (light: 0xC4271C, dark: 0xFF6961)
        static let ownBubble = (light: 0xBD4030, dark: 0xA8392A)
        static let onOwnBubble = (light: 0xFFFFFF, dark: 0xFFFFFF)
        static let incomingBubble = (light: 0xE9E9EB, dark: 0x262628)
    }

    /// The values that change with Increase Contrast on, each at 7:1 or more where ``Base``'s is 4.5:1.
    private enum Increased {
        static let accent = (light: 0x913125, dark: 0xFF9F8D)
        static let secondaryText = (light: 0x48484A, dark: 0xB8B8BB)
        static let positive = (light: 0x135E29, dark: 0x6BCD79)
        static let warning = (light: 0x853C00, dark: 0xFFA94D)
        static let critical = (light: 0x9E1F17, dark: 0xFF9E99)
        static let ownBubble = (light: 0x913125, dark: 0x7F2A1F)
    }
}
