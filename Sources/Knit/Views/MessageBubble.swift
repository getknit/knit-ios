#if os(iOS)
    import KnitAppCore
    import SwiftUI
    import UIKit

    /// One message: ours on the right with its tick, theirs on the left, with the author's face and name in the room and
    /// a group. The author's face and name open their profile, which is how a DM starts (MVP item 5). A photo sits above
    /// the words, and opens full screen. The content filter can hide either until a tap: an explicit photo (ADR
    /// 2026-10.rpmq), and words it flagged or has yet to read (ADR 2026-10.e4kz). In a run from one author (`place`), the
    /// name tops the first bubble and the face sits by the last, as Signal clusters them (ADR 2026-10.5waw). A long press
    /// opens its menu, Copy and Delete, and Report on someone else's, and VoiceOver offers them among its actions (ADR
    /// 2026-10.u7cq, ADR 2026-10.f6kf). Where the thread
    /// takes reactions, the menu opens on the six, and VoiceOver offers each as an action (ADR 2026-10.ehe6).
    internal struct MessageBubble: View {
        let message: ChatMessage
        /// Where it sits in its run.
        let place: MessagePlace
        /// Whether the message was tapped to show what the filter hid of it.
        let revealed: Bool
        /// Shows it.
        let reveal: () -> Void
        /// Opens the message's photo.
        let open: (ChatAttachment) -> Void
        /// Asks to delete the message.
        let delete: () -> Void
        /// Asks to report the message, or `nil` for one of ours.
        let report: (() -> Void)?
        /// Toggles our reaction with an emoji, or `nil` where the thread takes none.
        let react: ((String) -> Void)?
        @Environment(\.dynamicTypeSize) private var typeSize
        @Environment(PhotoScreening.self) private var screening: PhotoScreening?
        @Environment(\.openRoute) private var openRoute

        var body: some View {
            HStack(alignment: .bottom, spacing: Layout.small) {
                if message.isMine {
                    Spacer(minLength: Layout.bubbleInset)
                }
                // At the accessibility sizes the face would take the bubble's room; the name above it says who. Within a run
                // the face waits for the last bubble, and its column stays.
                if let face = message.authorFace, !typeSize.isAccessibilitySize {
                    if place.joinsNext {
                        Color.clear
                            .frame(width: Layout.faceBubble)
                    } else {
                        Button {
                            openRoute(.peer(message.author))
                        } label: {
                            AvatarView(face: face, size: Layout.faceBubble)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHidden(true)
                    }
                }
                BubbleContent(message: message, place: place, covered: covered, hidden: hidden, reveal: reveal, open: open, react: react)
                    .contextMenu {
                        BubbleMenu(message: message, copies: hidden == nil, delete: delete, report: report, react: react)
                    }
                if !message.isMine {
                    Spacer(minLength: Layout.bubbleInset)
                }
            }
            // A message reads as one element. Its photo stays a button for a tap, and VoiceOver opens it by name: the
            // photo as an element of its own left the author's name its own element too, a hit area too small to audit.
            .accessibilityElement(children: .combine)
            .accessibilityActions {
                if hidden == .flagged {
                    Button(Copy.Moderation.showMessage, action: reveal)
                }
                if let photo {
                    if covered {
                        Button(Copy.Moderation.showPhoto, action: reveal)
                    } else {
                        Button(Copy.Attachments.viewPhoto) { open(photo) }
                    }
                }
                if let react {
                    ForEach(ReactionChoices.six, id: \.self) { emoji in
                        Button(message.isOurReaction(emoji) ? Copy.Reactions.remove(emoji) : Copy.Reactions.react(emoji)) { react(emoji) }
                    }
                }
                Button(Copy.Delete.delete, action: delete)
                if let report {
                    Button(Copy.Report.report, action: report)
                }
            }
            .accessibilityValue(value)
            .accessibilityIdentifier(photo.map { _ in AccessibilityID.chatPhoto(message.id) } ?? AccessibilityID.chatMessage(message.id))
        }

        /// The message's photo, which opens full screen, or `nil` when it carries none.
        private var photo: ChatAttachment? {
            message.attachment.flatMap { $0.kind == .photo ? $0 : nil }
        }

        /// Whether the content filter hides the photo now: screened explicit, someone else's, and not tapped to show.
        private var covered: Bool {
            !revealed && photo.map { screening?.isHiding($0, isMine: message.isMine) == true } == true
        }

        /// Why the filter hides the words now, or `nil` while they show. Words it has yet to read never show on a tap.
        private var hidden: HiddenWords? {
            message.body.isEmpty || (revealed && message.hiddenWords == .flagged) ? nil : message.hiddenWords
        }

        /// What VoiceOver adds after the message: its time and tick when the run's stamp under a later bubble says them,
        /// what the filter hides of it, and its reactions.
        private var value: String {
            let time = Date(milliseconds: message.sentAt).formatted(date: .omitted, time: .shortened)
            let stamp = place.showsStamp ? [] : [time, message.status?.label]
            let hides = [hidden.map { _ in Copy.Moderation.hiddenMessage }, covered ? Copy.Moderation.hiddenPhotoValue : nil]
            return (stamp + hides + [message.reactionSummary])
                .compactMap(\.self)
                .joined(separator: ", ")
        }
    }

    /// A bubble's long-press menu: the six where the thread takes reactions, then Copy, Delete, and Report on someone
    /// else's (ADR 2026-10.u7cq, ADR 2026-10.f6kf).
    private struct BubbleMenu: View {
        let message: ChatMessage
        /// Whether the words show, so Copy can take them.
        let copies: Bool
        let delete: () -> Void
        let report: (() -> Void)?
        let react: ((String) -> Void)?

        var body: some View {
            if let react {
                ReactionPicker(message: message, react: react)
            }
            // Copy takes the words only while they show. The menu replaces the text's own selection, which a long press on
            // the words would otherwise open in its place.
            if copies, !message.body.isEmpty {
                Button(Copy.Chat.copy, systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = message.body
                }
                .accessibilityIdentifier(AccessibilityID.chatMessageCopy)
            }
            Button(Copy.Delete.delete, systemImage: "trash", role: .destructive, action: delete)
                .accessibilityIdentifier(AccessibilityID.chatMessageDelete)
            if let report {
                Button(Copy.Report.report, systemImage: "exclamationmark.bubble", role: .destructive, action: report)
                    .accessibilityIdentifier(AccessibilityID.chatMessageReport)
            }
        }
    }

    /// The six at the top of a bubble's menu, in one row (ADR 2026-10.ehe6): toggles in a palette, so ours shows chosen and
    /// choosing it again takes it back. A palette keeps its menu open after a choice, as for a multiple choice; a reaction
    /// is one choice, so this one closes it.
    private struct ReactionPicker: View {
        let message: ChatMessage
        let react: (String) -> Void

        var body: some View {
            ControlGroup {
                ForEach(ReactionChoices.six, id: \.self) { emoji in
                    Toggle(isOn: Binding(get: { message.isOurReaction(emoji) }, set: { _ in react(emoji) })) {
                        Text(emoji)
                    }
                }
            }
            .controlGroupStyle(.palette)
            .menuActionDismissBehavior(.enabled)
        }
    }

    /// A message's column: the author's name in the room and a group, which opens their profile, its photo, its words or
    /// what stands in for them, its reactions, and its stamp.
    private struct BubbleContent: View {
        let message: ChatMessage
        let place: MessagePlace
        /// Whether the photo hides until a tap.
        let covered: Bool
        /// Why the words hide, or `nil` while they show.
        let hidden: HiddenWords?
        let reveal: () -> Void
        let open: (ChatAttachment) -> Void
        let react: ((String) -> Void)?
        @Environment(\.openRoute) private var openRoute

        var body: some View {
            VStack(alignment: message.isMine ? .trailing : .leading, spacing: Layout.hairline) {
                if let author = message.authorLabel, !place.joinsPrevious {
                    Button {
                        openRoute(.peer(message.author))
                    } label: {
                        Text(author)
                            .font(.caption.bold())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
                if let attachment = message.attachment {
                    AttachmentView(attachment: attachment, isMine: message.isMine, covered: covered, reveal: reveal) { open(attachment) }
                }
                if let hidden {
                    HiddenWordsView(hidden: hidden, shape: shape, reveal: reveal)
                } else if !message.body.isEmpty {
                    Text(message.body)
                        .foregroundStyle(message.isMine ? AnyShapeStyle(Palette.onOwnBubble) : AnyShapeStyle(.primary))
                        .padding(.horizontal, Layout.medium)
                        .padding(.vertical, Layout.small)
                        .background(message.isMine ? Palette.ownBubble : Palette.incomingBubble, in: shape)
                }
                if !message.reactions.isEmpty {
                    ReactionStrip(message: message, react: react)
                }
                if place.showsStamp {
                    Stamp(message: message)
                }
            }
        }

        /// The bubble's outline: round, but tight on the author's side where it joins the bubble above, and at its foot,
        /// where Android draws its tail.
        private var shape: UnevenRoundedRectangle {
            let top = place.joinsPrevious ? Layout.bubbleJoin : Layout.bubbleCorner
            return message.isMine
                ? UnevenRoundedRectangle(
                    topLeadingRadius: Layout.bubbleCorner,
                    bottomLeadingRadius: Layout.bubbleCorner,
                    bottomTrailingRadius: Layout.bubbleJoin,
                    topTrailingRadius: top,
                    style: .continuous
                )
                : UnevenRoundedRectangle(
                    topLeadingRadius: top,
                    bottomLeadingRadius: Layout.bubbleJoin,
                    bottomTrailingRadius: Layout.bubbleCorner,
                    topTrailingRadius: Layout.bubbleCorner,
                    style: .continuous
                )
        }
    }

    /// What a bubble shows in place of words the filter hides: a line to tap for flagged words (`moderation_text_hidden`
    /// in knit-next), and a moment's wait for words it has yet to read. The line is decorative to VoiceOver, which hears
    /// the message's value and offers Show message instead.
    private struct HiddenWordsView: View {
        let hidden: HiddenWords
        let shape: UnevenRoundedRectangle
        let reveal: () -> Void

        var body: some View {
            Button(action: reveal) {
                Label {
                    Text(hidden == .flagged ? Copy.Moderation.hiddenWords : Copy.Moderation.checkingMessage)
                } icon: {
                    // The filter reads the words in a moment: Knit's stitches, while it does.
                    if hidden == .flagged {
                        Image(systemName: "eye.slash")
                    } else {
                        StitchIndicator()
                    }
                }
                .font(.subheadline.italic())
                .foregroundStyle(Palette.secondaryText)
                .padding(.horizontal, Layout.medium)
                .padding(.vertical, Layout.small)
                .background(Palette.incomingBubble, in: shape)
            }
            .buttonStyle(.plain)
            .disabled(hidden != .flagged)
            .accessibilityHidden(true)
        }
    }

    /// When a message was sent, and its tick when it is ours.
    private struct Stamp: View {
        let message: ChatMessage

        var body: some View {
            HStack(spacing: Layout.tight) {
                Text(Date(milliseconds: message.sentAt), style: .time)
                if let status = message.status {
                    DeliveryTick(status: status)
                        .accessibilityIdentifier(AccessibilityID.chatTick(message.id))
                }
            }
            .font(.caption2)
            .foregroundStyle(Palette.secondaryText)
        }
    }
#endif
