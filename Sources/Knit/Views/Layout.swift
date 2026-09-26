#if os(iOS)
    import CoreGraphics

    /// The app's spacings and sizes, named once so every screen keeps the same rhythm.
    internal enum Layout {
        /// Between a title and its subtitle.
        static let hairline: CGFloat = 2
        /// Between a row's lines.
        static let tight: CGFloat = 4
        /// Between related items.
        static let small: CGFloat = 8
        /// Between a glyph and its text.
        static let medium: CGFloat = 12
        /// Between blocks on a page.
        static let large: CGFloat = 16
        /// A page's margins.
        static let page: CGFloat = 24
        /// A wide page's margins.
        static let spacious: CGFloat = 32
        /// The column a row's leading glyph sits in.
        static let glyphColumn: CGFloat = 40
        /// A bubble's corners.
        static let bubbleCorner: CGFloat = 16
        /// How far a bubble stays from the far edge.
        static let bubbleInset: CGFloat = 48
        /// Our own bubbles' tint.
        static let ownBubbleOpacity = 0.2
        /// A preview's lines in a list.
        static let previewLines = 2
        /// How far the composer grows before it scrolls.
        static let composerLines = 1...6
    }
#endif
