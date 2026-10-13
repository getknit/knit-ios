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
        /// A card's corners.
        static let cardCorner: CGFloat = 16
        /// Knit's mark beside a heading.
        static let markInline: CGFloat = 22
        /// The disc around an info sheet's glyph.
        static let infoHero: CGFloat = 56
        /// The column an info sheet's point's glyph sits in.
        static let infoGlyph: CGFloat = 24
        /// Knit's mark heading the welcome page.
        static let markHero: CGFloat = 96
        /// The status line's dot, as Android draws it (8 dp).
        static let statusDot: CGFloat = 8
        /// A linked peer's dot on their face in the list, and the ring of background around it.
        static let badge: CGFloat = 14
        static let badgeRing: CGFloat = 2
        /// A bubble's corners.
        static let bubbleCorner: CGFloat = 18
        /// A bubble's corner on its author's side where it joins the next, and at its foot, as Android draws the tail.
        static let bubbleJoin: CGFloat = 4
        /// Between the bubbles of one run.
        static let clusterGap: CGFloat = 2
        /// A reaction chip's least height, ring included, so a short row of emoji still stands clear of the bubble, and a
        /// lone emoji's chip reads round rather than as a flat bar.
        static let chipHeight: CGFloat = 32
        /// A reaction chip's padding around its emoji, inside the ring.
        static let chipPaddingVertical: CGFloat = 5
        static let chipPaddingHorizontal: CGFloat = 9
        /// The tint's outline around our own reaction's chip.
        static let chipOutline: CGFloat = 1.5
        /// A thread's note's corners.
        static let noteCorner: CGFloat = 12
        /// A quote's accent bar, down its leading edge (`QuotedMessage`'s 3 dp in knit-next).
        static let quoteBar: CGFloat = 3
        /// A quote's corners, inside a bubble's (Android's 6 dp, a little rounder beside iOS's bubbles).
        static let quoteCorner: CGFloat = 10
        /// How far a bubble follows a swipe to reply before it stops, and how far the finger must go for the reply to start.
        static let swipeReach: CGFloat = 80
        static let swipeStarts: CGFloat = 56
        /// The composer's field's corners: a capsule at one line.
        static let composerCorner: CGFloat = 22
        /// The composer's glass panel's corners: the field's, plus the panel's padding around it.
        static let panelCorner: CGFloat = 30
        /// How far a bubble stays from the far edge.
        static let bubbleInset: CGFloat = 48
        /// The smallest side of a control's hit area, as Apple's guidelines and the accessibility audit want it.
        static let hitTarget: CGFloat = 44
        /// A preview's lines in a list.
        static let previewLines = 2
        /// How small the composer's button shrinks as Add photo and Send swap.
        static let swapScale: CGFloat = 0.6
        /// How far the composer grows before it scrolls.
        static let composerLines = 1...6
        /// A verify code's side, as Android shows it (200 dp).
        static let codeSide: CGFloat = 200
        /// The white margin around a verify code, which a scanner needs to find its edge.
        static let codeQuietZone: CGFloat = 12

        // A face's side on each surface, as Android sizes it.
        /// Ours, at the chat list's top left, where it opens Settings. Larger than Android's 32 dp: with no glass disc
        /// behind it, it stands opposite the 44-point compose button, and at 32 it read undersized.
        static let faceToolbar: CGFloat = 40
        /// A chat list row's.
        static let faceList: CGFloat = 52
        /// A thread's, beside its title.
        static let faceTitle: CGFloat = 36
        /// An author's, beside their message.
        static let faceBubble: CGFloat = 40
        /// Someone typing's, at a thread's foot (`TypingIndicatorRow`'s 30 dp).
        static let faceTyping: CGFloat = 30
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
