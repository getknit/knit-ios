#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// The thread's messages, newest at the bottom, with what the thread says about itself above them. Each day starts
    /// under its date, and a run from one author clusters, as Signal draws it (``MessageClusters``). UIKit holds the rows
    /// and their scrolling (``ThreadCollection``), and SwiftUI draws each one.
    internal struct MessageList: View {
        let state: ChatState
        /// The messages tapped to show what the filter hid of them.
        let revealed: Set<String>
        /// Shows what the filter hid of a message.
        let reveal: (String) -> Void
        /// Opens a message's photo full screen.
        let view: (ViewedPhoto) -> Void
        /// Asks to delete a message, from its menu.
        let delete: (ChatMessage) -> Void
        /// Asks to report a message, from its menu, or `nil` for one that cannot be reported.
        let report: (ChatMessage) -> (() -> Void)?
        /// Toggles our reaction to a message, or `nil` where the thread takes none.
        let react: Reacting?
        /// Whether the way back to the newest message shows: from half a screen up the thread until it is back on its bottom
        /// edge, so it stays while someone scrolls down toward it (`showScrollToNewest` in knit-next's `ChatScreen.kt`).
        @State private var offersNewest = false
        @State private var jump = ThreadJump()
        @Environment(BlobImageCache.self) private var photos: BlobImageCache?
        @Environment(PhotoScreening.self) private var screening: PhotoScreening?
        @Environment(\.calendar) private var calendar
        @Environment(\.openRoute) private var openRoute
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let places = MessageClusters.places(state.messages, calendar: calendar)
            let items = [ThreadItem.header] + state.messages.map { .message($0.id) }
            var rows = [ThreadItem.header: Row.header(ThreadHeader.Facts(state))]
            for (message, place) in zip(state.messages, places) {
                rows[.message(message.id)] = .message(message, place: place, revealed: revealed.contains(message.id))
            }
            // The thread reaches under the bars, inset by them as SwiftUI lays them out.
            return GeometryReader { proxy in
                // A cell's SwiftUI is its own, outside this view's: what the rows read from their surroundings goes in by hand.
                ThreadCollection(items: items, rows: rows, jump: jump, bars: proxy.safeAreaInsets, offersNewest: $offersNewest) { row in
                    content(of: row)
                        .environment(photos)
                        .environment(screening)
                        .environment(\.calendar, calendar)
                        .environment(\.openRoute, openRoute)
                        .tint(Palette.accent)
                }
                .ignoresSafeArea()
            }
            .overlay(alignment: .bottomTrailing) {
                ZStack {
                    if offersNewest {
                        NewestButton(jump: jump.toNewest)
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
                if state.messages.last?.isMine == true || !offersNewest {
                    jump.toNewest()
                }
            }
        }

        /// What one row of the thread shows.
        private enum Row: Equatable {
            case header(ThreadHeader.Facts)
            case message(ChatMessage, place: MessagePlace, revealed: Bool)
        }

        /// A row: what the thread says about itself, or a message under its day's date when it starts one.
        @ViewBuilder
        private func content(of row: Row) -> some View {
            switch row {
            case .header(let facts):
                ThreadHeader(facts: facts)
            case .message(let message, let place, let revealed):
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
                            revealed: revealed,
                            reveal: { reveal(message.id) },
                            open: { view(.chat($0, sender: sender(of: message))) },
                            delete: { delete(message) },
                            report: report(message),
                            react: react?.to(message)
                        )
                    }
                }
                // Bubbles in a run sit close; runs sit apart.
                .padding(.top, place.joinsPrevious ? Layout.clusterGap : Layout.small)
            }
        }

        /// Who sent `message`, as the viewer's bar names them: "You", the author's label, or a DM's peer.
        private func sender(of message: ChatMessage) -> String {
            message.isMine ? Copy.Common.you : message.authorLabel ?? state.title
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
        /// What the header says depends on: a row draws again only when these change.
        struct Facts: Equatable {
            let isRoom: Bool
            let isEmpty: Bool
            let isDirect: Bool
            let isLinked: Bool
            let title: String

            init(_ state: ChatState) {
                isRoom = state.isRoom
                isEmpty = state.messages.isEmpty
                isDirect = state.peer != nil
                isLinked = state.isLinked
                title = state.title
            }
        }

        let facts: Facts

        var body: some View {
            VStack(spacing: 0) {
                if facts.isRoom {
                    ThreadNote(text: Copy.Chat.roomNotice, symbol: "person.3")
                    if facts.isEmpty {
                        ThreadNote(text: Copy.Chat.roomEmpty, symbol: "hand.wave")
                    }
                } else if facts.isDirect {
                    if !facts.isLinked {
                        ThreadNote(text: Copy.Chat.outOfRange)
                    }
                    if facts.isEmpty {
                        ThreadNote(text: Copy.Chat.directEmpty(facts.title), symbol: "lock")
                    }
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
