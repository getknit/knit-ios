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
        /// The smallest side of a control's hit area, as Apple's guidelines and the accessibility audit want it.
        static let hitTarget: CGFloat = 44
        /// A preview's lines in a list.
        static let previewLines = 2
        /// How far the composer grows before it scrolls.
        static let composerLines = 1...6
        /// A verify code's side, as Android shows it (200 dp).
        static let codeSide: CGFloat = 200
        /// The white margin around a verify code, which a scanner needs to find its edge.
        static let codeQuietZone: CGFloat = 12

        // A face's side on each surface, as Android sizes it.
        /// A chat list row's.
        static let faceList: CGFloat = 52
        /// A thread's, beside its title.
        static let faceTitle: CGFloat = 36
        /// An author's, beside their message.
        static let faceBubble: CGFloat = 40
        /// A request's.
        static let faceRequest: CGFloat = 44
        /// A group member's, and a contact's in New message.
        static let faceRow: CGFloat = 48
        /// Settings' profile row's.
        static let faceSettings: CGFloat = 56
        /// A profile's, ours and anyone's.
        static let faceProfile: CGFloat = 96

        // A photo in a thread, as Android sizes it (`ATTACHMENT_WIDTH` and the rest in `ChatScreen.kt`).
        /// A photo's width in its bubble, unless it is too tall for it.
        static let photoWidth: CGFloat = 220
        /// The tallest a photo stands in its bubble.
        static let photoMaxHeight: CGFloat = 260
        /// The side of the placeholder a photo shows until its bytes are here, or when they do not open.
        static let photoPlaceholder: CGFloat = 160
        /// A photo's corner.
        static let photoCorner: CGFloat = 12
        /// The side of the photo the composer holds.
        static let stagedPhoto: CGFloat = 72
        /// How long a missing photo's spinner turns, in seconds, before it settles to an hourglass
        /// (`SPINNER_PATIENCE_MS`): an endless spinner keeps the screen drawing every frame for as long as the photo is
        /// owed.
        static let photoPatience = 30
    }
#endif
