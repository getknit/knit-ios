#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// A bubble's words as Android's `annotateMessageBody` draws them: the names its message mentions set semibold where the
    /// sender wrote them (ADR 2026-10.nbhj), and its web addresses as underlined links (ADR 2026-11.w5ew), both in
    /// ``linkColor(isMine:)``. A mention is no button, as on Android, so VoiceOver reads the words as written.
    internal enum BubbleText {
        /// What a mention and a link draw in: ``Palette/mention`` in someone else's bubble, and in our own the bubble's own
        /// words' color, since nothing else reads on our coral (Android's `accentText`, `readableOn` the bubble).
        static func linkColor(isMine: Bool) -> Color {
            isMine ? Palette.onOwnBubble : Palette.mention
        }

        static func body(_ message: ChatMessage) -> AttributedString {
            var styled = AttributedString(message.body)
            let units = message.body.utf16
            for span in message.mentionSpans where span.upperBound <= units.count {
                let lower = String.Index(utf16Offset: span.lowerBound, in: message.body)
                let upper = String.Index(utf16Offset: span.upperBound, in: message.body)
                guard let range = Range(lower..<upper, in: styled) else {
                    continue
                }
                styled[range].font = .body.weight(.semibold)
                if !message.isMine {
                    styled[range].foregroundColor = Palette.mention
                }
            }
            for link in message.links where link.range.upperBound <= units.count {
                let lower = String.Index(utf16Offset: link.range.lowerBound, in: message.body)
                let upper = String.Index(utf16Offset: link.range.upperBound, in: message.body)
                guard let url = link.target, let range = Range(lower..<upper, in: styled) else {
                    continue
                }
                // A tap opens it through the environment's `openURL`, which keeps a contact link in Knit (`KnitApp`).
                styled[range].link = url
                styled[range].underlineStyle = Text.LineStyle.single
                styled[range].foregroundColor = linkColor(isMine: message.isMine)
            }
            return styled
        }
    }
#endif
