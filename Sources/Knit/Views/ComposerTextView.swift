#if os(iOS)
    import KnitAppCore
    import SwiftUI
    import UIKit

    /// The composer's field: a text view, so a picked name shows as a chip and edits as one (ADR 2026-10.nbhj), as Android's
    /// `MentionChips` and Signal's `BodyRangesTextView` make it. SwiftUI's `TextField` styles no range and reports an edit
    /// only as the text after it, so a chip could neither show nor learn which way a backspace went.
    ///
    /// The model keeps the words, the picks and the selection. The field asks it about every edit that could cut into a chip
    /// and every move of the cursor, and draws the chips it reports. It grows a line at a time to ``Layout/composerLines``'
    /// last, then scrolls.
    internal struct ComposerTextView: UIViewRepresentable {
        let model: ChatModel
        /// The words, the selection and the chips, read where the bar draws so a change to any of them updates the field.
        let draft: String
        let selection: Range<Int>
        let chips: [Range<Int>]
        /// Whether the field has the keyboard, which a reply started elsewhere asks for.
        @Binding var focused: Bool
        /// The reader's text size, read so a change redraws the chips at the new size.
        @Environment(\.dynamicTypeSize) private var typeSize

        func makeCoordinator() -> Coordinator {
            Coordinator(model: model, focused: $focused)
        }

        func makeUIView(context: Context) -> UITextView {
            let field = UITextView()
            field.delegate = context.coordinator
            field.font = Coordinator.bodyFont
            field.adjustsFontForContentSizeCategory = true
            field.textColor = .label
            field.backgroundColor = .clear
            field.textContainerInset = .zero
            field.textContainer.lineFragmentPadding = 0
            field.isScrollEnabled = false
            // A paste lands as plain words: a chip is the model's, never something carried in on the pasteboard.
            field.allowsEditingTextAttributes = false
            field.accessibilityLabel = Copy.Chat.composerPlaceholder
            // On the text view itself: given to the SwiftUI wrapper, the identifier lands on the placeholder drawn over
            // it, which the UI tests can tap but not type into.
            field.accessibilityIdentifier = AccessibilityID.chatInput
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            context.coordinator.show(model.draft, chips: model.chips, in: field)
            return field
        }

        func updateUIView(_ field: UITextView, context: Context) {
            // Read so a change of text size calls this again, which draws the chips at the new size.
            _ = typeSize
            let coordinator = context.coordinator
            coordinator.model = model
            coordinator.focused = $focused
            if field.text != draft {
                coordinator.show(draft, chips: chips, in: field)
            } else if field.markedTextRange == nil {
                coordinator.restyle(field, chips: chips)
            }
            coordinator.select(selection, in: field)
            if focused, !field.isFirstResponder, field.window != nil {
                field.becomeFirstResponder()
            }
        }

        /// The words' height at `proposal`'s width, from one line to the composer's most, past which the field scrolls.
        func sizeThatFits(_ proposal: ProposedViewSize, uiView field: UITextView, context _: Context) -> CGSize? {
            guard let width = proposal.width, width.isFinite, width > 0 else {
                return nil
            }
            let fitting = field.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            let line = field.font?.lineHeight ?? fitting.height
            let most = (line * CGFloat(Layout.composerLines.upperBound)).rounded(.up)
            let scrolls = fitting.height > most
            if field.isScrollEnabled != scrolls {
                field.isScrollEnabled = scrolls
            }
            return CGSize(width: width, height: min(max(fitting.height, line), most))
        }

        /// The text view's delegate, between it and the model.
        @MainActor
        final class Coordinator: NSObject, UITextViewDelegate {
            /// The body font, sized for the reader's text size.
            static var bodyFont: UIFont {
                UIFont.preferredFont(forTextStyle: .body)
            }

            /// A chip's font: the body's at the reader's size, semibold, as Android's chip.
            private static var chipFont: UIFont {
                let body = bodyFont
                let semibold = body.fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]])
                return UIFont(descriptor: semibold, size: body.pointSize)
            }

            var model: ChatModel
            var focused: Binding<Bool>
            /// The text and selection the field showed at the last change it reported, which tells a move of the cursor
            /// from an edit, and which way an arrow key went.
            private var shown = ""
            private var previous: Range<Int>?
            /// Whether the field is being changed from here, whose own reports are echoes.
            private var applying = false

            init(model: ChatModel, focused: Binding<Bool>) {
                self.model = model
                self.focused = focused
            }

            // MARK: Drawing

            /// Shows `text` in `field`, with `chips` drawn.
            func show(_ text: String, chips: [Range<Int>], in field: UITextView) {
                applying = true
                defer { applying = false }
                field.attributedText = styled(text, chips: chips)
                field.typingAttributes = Self.plain
                shown = text
            }

            /// Draws `chips` again over the words the field holds, which keep their place and the selection.
            func restyle(_ field: UITextView, chips: [Range<Int>]) {
                let wanted = styled(field.text, chips: chips)
                guard field.attributedText != wanted else {
                    return
                }
                applying = true
                defer { applying = false }
                let kept = field.selectedRange
                field.attributedText = wanted
                field.selectedRange = kept
                field.typingAttributes = Self.plain
            }

            /// Puts `field`'s selection at `range` when the model moved it, as a pick or a whole-chip delete does.
            func select(_ range: Range<Int>, in field: UITextView) {
                let wanted = NSRange(location: range.lowerBound, length: range.count)
                guard field.markedTextRange == nil, field.selectedRange != wanted, NSMaxRange(wanted) <= field.text.utf16.count else {
                    return
                }
                applying = true
                defer { applying = false }
                field.selectedRange = wanted
                previous = range
            }

            /// `text` in the body's look, with each of `chips` semibold on a gray of its own. A chip keeps the label color,
            /// which reads on that gray in light, dark and with Increase Contrast.
            private func styled(_ text: String, chips: [Range<Int>]) -> NSAttributedString {
                let drawn = NSMutableAttributedString(string: text, attributes: Self.plain)
                let length = text.utf16.count
                for span in chips where span.upperBound <= length {
                    drawn.addAttributes(Self.chip, range: NSRange(location: span.lowerBound, length: span.count))
                }
                return drawn
            }

            private static var plain: [NSAttributedString.Key: Any] {
                [.font: bodyFont, .foregroundColor: UIColor.label]
            }

            private static var chip: [NSAttributedString.Key: Any] {
                [.font: chipFont, .foregroundColor: UIColor.label, .backgroundColor: UIColor.systemGray4]
            }

            // MARK: The field's reports

            func textView(_ field: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
                // The keyboard's own composing, a kana run say, is the keyboard's until it commits.
                guard !applying, field.markedTextRange == nil else {
                    return true
                }
                if field.text != model.draft {
                    model.draft = field.text
                }
                guard model.keepChipsWhole(replacing: range.location..<NSMaxRange(range), with: text) else {
                    return true
                }
                show(model.draft, chips: model.chips, in: field)
                select(model.selection, in: field)
                return false
            }

            func textViewDidChange(_ field: UITextView) {
                guard !applying else {
                    return
                }
                model.draft = field.text
                shown = field.text
                if field.markedTextRange == nil {
                    restyle(field, chips: model.chips)
                }
                // The model may have cut the words at the limit.
                if field.text != model.draft {
                    show(model.draft, chips: model.chips, in: field)
                }
            }

            func textViewDidChangeSelection(_ field: UITextView) {
                guard !applying, field.markedTextRange == nil else {
                    return
                }
                let range = field.selectedRange
                let moved = range.location..<NSMaxRange(range)
                // A move that changed no words says which way it went; after an edit the old offsets no longer line up.
                let from = field.text == shown ? previous : nil
                if field.text != model.draft {
                    model.draft = field.text
                }
                shown = field.text
                let snapped = model.select(moved, from: from)
                previous = snapped
                if snapped != moved {
                    select(snapped, in: field)
                }
            }

            func textViewDidBeginEditing(_: UITextView) {
                if !focused.wrappedValue {
                    focused.wrappedValue = true
                }
            }

            func textViewDidEndEditing(_: UITextView) {
                if focused.wrappedValue {
                    focused.wrappedValue = false
                }
            }
        }
    }
#endif
