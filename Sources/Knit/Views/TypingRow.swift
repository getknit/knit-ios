#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// Who is typing, at the thread's foot (`TypingIndicatorRow` in knit-next's `ChatScreen.kt`): up to three faces,
    /// overlapping, beside a bubble drawn like someone else's that holds Knit's stitches. It shows no words. VoiceOver reads
    /// the row as one element named for who is typing, and never announces it: Android doesn't, and a cue every few seconds
    /// would talk over whatever is being read.
    internal struct TypingRow: View {
        /// The most faces shown (`typing.take(3)`).
        private static let faces = 3
        /// How far each face tucks under the one before it (Android's 10 dp).
        private static let overlap: CGFloat = 10

        let typists: [Typist]
        let label: String

        var body: some View {
            HStack(spacing: Layout.small) {
                HStack(spacing: -Self.overlap) {
                    ForEach(typists.prefix(Self.faces)) { typist in
                        AvatarView(face: typist.face, size: Layout.faceTyping)
                    }
                }
                StitchIndicator()
                    .padding(.horizontal, Layout.medium)
                    .padding(.vertical, Layout.medium)
                    .background(Palette.incomingBubble, in: Self.bubble)
                Spacer(minLength: 0)
            }
            .padding(.top, Layout.small)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityIdentifier(AccessibilityID.chatTyping)
        }

        /// Someone else's bubble at the foot of a run: round, but tight where Android draws its tail.
        private static let bubble = UnevenRoundedRectangle(
            topLeadingRadius: Layout.bubbleCorner,
            bottomLeadingRadius: Layout.bubbleJoin,
            bottomTrailingRadius: Layout.bubbleCorner,
            topTrailingRadius: Layout.bubbleCorner,
            style: .continuous
        )
    }
#endif
