#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// The message a reply quotes (`QuotedMessage` in knit-next's `ChatScreen.kt`, ADR 2026-10.mn29): an accent bar, the
    /// author on one line, and what they said on up to two. It sits above a reply's photo and words in the thread, and above
    /// the field while the composer holds one. A blocked author's quote says so, in the hidden words' italic.
    ///
    /// It takes the colors of the bubble it belongs to, so its words read as the bubble's own do: on ours, the bubble's text
    /// color throughout; on someone else's, the tint for the bar and the secondary text for the words, as a hidden message's
    /// line reads on the same fill.
    internal struct QuoteView: View {
        let quote: ChatQuote
        /// Whether it is ours, on our own bubble's fill.
        let isMine: Bool

        var body: some View {
            HStack(alignment: .top, spacing: Layout.small) {
                Capsule()
                    .fill(isMine ? AnyShapeStyle(Palette.onOwnBubble) : AnyShapeStyle(Palette.accent))
                    .frame(width: Layout.quoteBar)
                VStack(alignment: .leading, spacing: 0) {
                    if !quote.author.isEmpty {
                        Text(quote.author)
                            .font(.caption.bold())
                            .lineLimit(1)
                            .foregroundStyle(isMine ? AnyShapeStyle(Palette.onOwnBubble) : AnyShapeStyle(.primary))
                    }
                    if let line = quote.line {
                        Text(line)
                            .font(quote.blocked ? .caption.italic() : .caption)
                            .lineLimit(Layout.previewLines)
                            .foregroundStyle(isMine ? Palette.onOwnBubble : Palette.secondaryText)
                    }
                }
                .multilineTextAlignment(.leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Layout.medium)
            .padding(.vertical, Layout.small)
            .background(
                isMine ? Palette.ownBubble : Palette.incomingBubble, in: .rect(cornerRadius: Layout.quoteCorner, style: .continuous)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Copy.Replies.quote(quote.author, line: quote.line))
        }
    }

    /// The composer's quote while it holds one (`ReplyPreview` in knit-next): the quote, and Cancel reply beside it.
    internal struct ReplyBar: View {
        let quote: ChatQuote
        let cancel: () -> Void

        var body: some View {
            HStack(alignment: .center, spacing: Layout.small) {
                QuoteView(quote: quote, isMine: false)
                    .accessibilityLabel(Copy.Replies.replying(to: quote.author, line: quote.line))
                    .accessibilityIdentifier(AccessibilityID.chatReplyBar)
                Spacer(minLength: 0)
                Button(action: cancel) {
                    Label(Copy.Replies.cancel, systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .foregroundStyle(Palette.secondaryText)
                        // The screen's own color behind it, opaque: inside the composer's glass it would turn translucent.
                        .background(Color(uiColor: .systemBackground), in: .circle)
                        .frame(minWidth: Layout.hitTarget, minHeight: Layout.hitTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.chatReplyCancel)
            }
        }
    }
#endif
