#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// The thread's messages, newest at the bottom, with what the thread says about itself above them. Each day starts
    /// under its date, and a run from one author clusters, as Signal draws it (``MessageClusters``).
    internal struct MessageList: View {
        /// How far up the thread, in screens, the way back to the newest message shows: by then the newest is out of sight,
        /// and a glance back up a message or two stays clear of it.
        private static let wayBackScreens: CGFloat = 0.5

        let state: ChatState
        /// The messages tapped to show what the filter hid of them.
        let revealed: Set<String>
        /// Shows what the filter hid of a message.
        let reveal: (String) -> Void
        /// Opens a message's photo full screen.
        let view: (ViewedPhoto) -> Void
        /// Asks to delete a message, from its menu.
        let delete: (ChatMessage) -> Void
        /// Toggles our reaction to a message, or `nil` where the thread takes none.
        let react: Reacting?
        /// Where the thread rests: at its bottom edge, below the newest message's padding. A position on the edge stays on
        /// it as a row grows, where one scrolled to the newest message's id did not: a photo holds a spinner's place until
        /// it decodes, then stands up to a hundred points taller, which left its stamp and tick under the composer.
        @State private var position = ScrollPosition(edge: .bottom)
        /// Whether the thread keeps to its bottom edge: from opening until someone scrolls away, and again once they scroll
        /// back. The lazy stack guesses the height of rows it has yet to draw, and the edge it opens on moves as it draws
        /// them; a long room opened short of its newest posts, or past them over empty space.
        @State private var followsBottom = true
        /// Whether the offset is rising off the bottom edge with no finger on it, reading after reading (see
        /// ``follow(to:)``).
        @State private var rising = false
        /// Whether a finger is on the thread, or it is still gliding from one.
        @State private var scrolling = false
        /// The last reading ``follow(to:)`` took, which the next is measured against.
        @State private var reading: Reach?
        /// Whether the way back to the newest message shows: from half a screen up the thread until it is back on its bottom
        /// edge, so it stays while someone scrolls down toward it (`showScrollToNewest` in knit-next's `ChatScreen.kt`).
        @State private var offersNewest = false
        @Environment(BlobImageCache.self) private var photos: BlobImageCache?
        @Environment(\.calendar) private var calendar
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ThreadHeader(state: state)
                    let places = MessageClusters.places(state.messages, calendar: calendar)
                    ForEach(Array(zip(state.messages, places)), id: \.0.id) { message, place in
                        VStack(spacing: Layout.small) {
                            if place.startsDay {
                                DaySeparator(sentAt: message.sentAt)
                            }
                            if let notice = message.notice {
                                ThreadNote(text: notice)
                                    .accessibilityIdentifier(AccessibilityID.chatNotice(message.id))
                            } else {
                                MessageBubble(
                                    message: message,
                                    place: place,
                                    revealed: revealed.contains(message.id),
                                    reveal: { reveal(message.id) },
                                    open: { view(.chat($0, sender: sender(of: message))) },
                                    delete: { delete(message) },
                                    react: react?.to(message)
                                )
                            }
                        }
                        // Bubbles in a run sit close; runs sit apart.
                        .padding(.top, place.joinsPrevious ? Layout.clusterGap : Layout.small)
                    }
                }
                .padding()
            }
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier(AccessibilityID.chatThread)
            .overlay(alignment: .bottomTrailing) {
                ZStack {
                    if offersNewest {
                        NewestButton(jump: jumpToNewest)
                            .padding(Layout.large)
                            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: offersNewest)
            }
            // Our own message takes the thread down to it, and so does anyone's while the thread is near its bottom. Someone
            // else's leaves a reader up in history where they are, with the way back showing (`ChatScreen.kt`'s
            // `row.mine || listState.firstVisibleItemIndex <= 1`).
            .onChange(of: state.messages.last?.id) {
                guard state.messages.last?.isMine == true || !offersNewest else {
                    return
                }
                followsBottom = true
                position.scrollTo(edge: .bottom)
            }
            // The edge moves as rows are drawn, a photo decodes, the composer grows or the keyboard rises.
            .onScrollGeometryChange(for: Reach.self, of: Reach.init) { _, new in
                follow(to: new)
            }
            .onScrollPhaseChange { _, phase, context in
                switch phase {
                case .tracking, .interacting, .decelerating:
                    scrolling = true
                    followsBottom = false
                case .idle:
                    scrolling = false
                    followsBottom = Reach(context.geometry).isAtBottom
                case .animating:
                    break
                @unknown default:
                    break
                }
            }
            // Each photo's shape is read ahead, newest first since the thread opens at its bottom, so a photo scrolled up to
            // stands at its own height from the start, rather than a spinner's that grows and pushes the thread down.
            .task(id: state.messages.compactMap(\.attachment)) {
                await photos?.measure(state.messages.reversed().compactMap(\.attachment))
            }
        }

        /// Keeps the thread on its bottom edge while it follows it, and offers the way back once it is well above it.
        ///
        /// A finger's scroll reports its phase, but iOS's own scroll to the top, on a tap on the status bar or on the empty
        /// part of the navigation bar, reports none. Pulled back down as it passed rows whose height the lazy stack had only
        /// guessed, it flashed the thread, and finished at the top only when no guess changed on the way. A rise of the
        /// content off the bottom edge is that scroll once a second reading rises too. One reading is not enough: when the
        /// composer or the keyboard changes height, the container changes a reading before the insets do, and the offset
        /// dips by the difference until they catch up. The thread holds still while the offset climbs, and follows again
        /// at the first reading where it stops: a rise that outlived its climb held the thread off its edge as it opened,
        /// while every row it drew moved the edge further down.
        ///
        /// Each reading is measured against the last one this took, not against the `old` value the change hands over. As a
        /// thread opened, that value paired the offset of the lazy stack's first guess with the container the bars had
        /// settled, which read as a climb of thousands of points, and a reopened room stopped 150 points short of its newest
        /// post. A thread past its bottom edge with no finger on it goes back to the edge, following or not. When a long
        /// room's rows replaced the first guess at its height, the offset stayed where the guess had put it, far below the
        /// content's end, and the room showed nothing until it was dragged (2026-10-05, 2,167 posts on an iPhone 12).
        private func follow(to new: Reach) {
            let old = reading ?? new
            reading = new
            let rises = new.rose(from: old) && !new.isAtBottom
            if rises, rising {
                followsBottom = false
            }
            rising = rises || (rising && new.top < old.top && !new.isAtBottom)
            if new.isPastBottom, !scrolling {
                followsBottom = true
                position.scrollTo(edge: .bottom)
            } else if followsBottom, !rising, !new.isAtBottom {
                position.scrollTo(edge: .bottom)
            }
            if !followsBottom, new.away > new.screen * Self.wayBackScreens {
                offersNewest = true
            } else if new.isAtBottom {
                offersNewest = false
            }
        }

        /// Jumps to the newest message rather than gliding: a glide draws every row it passes, and Android and Signal jump
        /// for the same reason.
        private func jumpToNewest() {
            followsBottom = true
            position.scrollTo(edge: .bottom)
        }

        /// Who sent `message`, as the viewer's bar names them: "You", the author's label, or a DM's peer.
        private func sender(of message: ChatMessage) -> String {
            message.isMine ? Copy.Common.you : message.authorLabel ?? state.title
        }
    }

    /// Where a thread stands against its bottom edge, in one reading of its scroll geometry.
    private struct Reach: Equatable {
        /// Where the content stands at the top of the container, the part of the thread between the bars: the offset,
        /// which counts from the top of the screen, plus the top inset. The inset settles as the thread opens, and moves
        /// the offset with it, but not the content.
        let top: CGFloat
        /// The `top` that shows the thread's bottom edge above the composer. Content shorter than the container puts its
        /// padding in the top inset, which leaves this below zero.
        let end: CGFloat
        /// The height of the thread between the bars.
        let screen: CGFloat

        init(_ geometry: ScrollGeometry) {
            top = geometry.contentOffset.y + geometry.contentInsets.top
            end = geometry.contentSize.height - geometry.containerSize.height
            screen = geometry.containerSize.height
        }

        /// How far up the thread stands from its bottom edge; zero or less on it.
        var away: CGFloat {
            end - top
        }

        /// Whether the thread stands on its bottom edge, near enough.
        var isAtBottom: Bool {
            away <= Layout.small
        }

        /// Whether the thread stands past its bottom edge, over empty space: content that shrank as the lazy stack drew rows
        /// it had guessed taller, under an offset nothing moved.
        var isPastBottom: Bool {
            top > max(end, 0) + Layout.small
        }

        /// Whether the content rose from `old`, toward older messages, further than the edge did, in a container of the
        /// same height: a scroll. A row's change of height moves the two together, the thread's first layout and the bars'
        /// change of height change the container, and an inset that settles moves neither.
        func rose(from old: Self) -> Bool {
            screen == old.screen && old.top - top > max(old.end - end, 0) + Layout.small
        }
    }

    /// The way back to the newest message for someone scrolled up the thread: a round button over its bottom trailing corner,
    /// above the composer, as Signal draws it (`ScrollToNewestButton` in knit-next's `ChatScreen.kt`). From iOS 26 it is
    /// Liquid Glass; before that, and with Reduce Transparency on, an opaque disc (ADR 2026-10.5waw).
    private struct NewestButton: View {
        let jump: () -> Void
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

        var body: some View {
            let button = Button(action: jump) {
                Label(Copy.Chat.scrollToNewest, systemImage: "chevron.down")
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .frame(width: Layout.hitTarget, height: Layout.hitTarget)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.chatScrollToNewest)
            if #available(iOS 26, *), !reduceTransparency {
                button
                    .glassEffect(.regular.interactive(), in: .circle)
            } else {
                // The shadow gives the disc an edge over the bubbles it floats above.
                button
                    .background(.background.secondary, in: .circle)
                    .shadow(radius: Layout.hairline)
            }
        }
    }

    /// The room's notice, what an out-of-range DM means, and what an empty thread holds. A group's size is under the title.
    private struct ThreadHeader: View {
        let state: ChatState

        var body: some View {
            if state.isRoom {
                ThreadNote(text: Copy.Chat.roomNotice, symbol: "person.3")
                if state.messages.isEmpty {
                    ThreadNote(text: Copy.Chat.roomEmpty, symbol: "hand.wave")
                }
            } else if state.peer != nil {
                if !state.isLinked {
                    ThreadNote(text: Copy.Chat.outOfRange)
                }
                if state.messages.isEmpty {
                    ThreadNote(text: Copy.Chat.directEmpty(state.title), symbol: "lock")
                }
            }
        }
    }

    /// The date over a day's first message, as the system words it: Today, Yesterday, or the date.
    private struct DaySeparator: View {
        private static let formatter: DateFormatter = {
            let style = DateFormatter()
            style.dateStyle = .medium
            style.timeStyle = .none
            style.doesRelativeDateFormatting = true
            return style
        }()

        let sentAt: Int64

        var body: some View {
            ThreadNote(text: Self.formatter.string(from: Date(milliseconds: sentAt)))
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// A line the thread says about itself rather than a message: a group's event, the room's notice, a day's date. It sits
    /// centered on a gray capsule, opaque, so it reads the same over any thread.
    private struct ThreadNote: View {
        let text: String
        var symbol: String?

        var body: some View {
            Group {
                if let symbol {
                    Label(text, systemImage: symbol)
                } else {
                    Text(text)
                }
            }
            .font(.footnote)
            .foregroundStyle(Palette.secondaryText)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Layout.medium)
            .padding(.vertical, Layout.tight)
            .background(Palette.incomingBubble, in: .rect(cornerRadius: Layout.noteCorner, style: .continuous))
            .frame(maxWidth: .infinity)
            .padding(.vertical, Layout.tight)
        }
    }

    /// What toggles our reaction to a message, from its menu, a chip or VoiceOver (ADR 2026-10.ehe6).
    @MainActor
    internal struct Reacting {
        let model: ChatModel

        /// What toggles our reaction to `message` with an emoji.
        func to(_ message: ChatMessage) -> (String) -> Void {
            { emoji in Task { await model.react(to: message, with: emoji) } }
        }
    }
#endif
