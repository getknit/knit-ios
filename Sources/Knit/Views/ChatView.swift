#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// A thread: the room, a DM or a group, its messages and status lines, a request's Accept and Block, a blocked DM's
    /// Unblock, and the composer.
    internal struct ChatView: View {
        @State private var model: ChatModel
        @State private var showsEncryption = false
        @State private var viewing: ViewedPhoto?
        /// Whether a request's Block is asking first.
        @State private var confirmsBlock = false
        /// The message whose Delete is asking first (ADR 2026-10.u7cq).
        @State private var deleting: ChatMessage?
        /// The messages tapped to show what the content filter hid of them, photo and words, while the thread is open (ADR
        /// 2026-10.rpmq, ADR 2026-10.e4kz).
        @State private var revealed: Set<String> = []
        @Environment(\.dismiss) private var dismiss
        /// What Add photo picks under `-demoPhoto`, in place of the photo library.
        private let demoPhoto: Data?

        /// The thread `conversationId` over `session`, making picked photos ready to send through `codec` and checking them
        /// with `screening`.
        init(conversationId: String, session: AppSession, codec: any ImageCodec, screening: PhotoScreening, demoPhoto: Data?) {
            _model = State(initialValue: ChatModel(conversationId: conversationId, session: session, codec: codec, screening: screening))
            self.demoPhoto = demoPhoto
        }

        var body: some View {
            let state = model.state
            MessageList(
                state: state,
                revealed: revealed,
                reveal: { revealed.insert($0) },
                view: { viewing = $0 },
                delete: askToDelete,
                react: state.canReact ? Reacting(model: model) : nil
            )
            .bottomBar {
                if state.isRequest {
                    RequestBar(
                        title: state.requestTitle,
                        explanation: state.requestBody,
                        accept: { Task { await model.accept() } },
                        // A group's request has nobody to block.
                        block: state.peer == nil ? nil : { confirmsBlock = true }
                    )
                } else if state.isBlocked {
                    BlockedBar(name: state.title) { Task { await model.unblock() } }
                } else if state.nobodyElse {
                    NobodyLeftBar()
                } else {
                    ComposerBar(model: model, demoPhoto: demoPhoto)
                }
            }
            .navigationTitle(state.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ThreadTitle(state: state, conversationId: model.conversationId)
                }
                // What is sealed, on the lock: the one place Knit's thread keeps a button Signal's has not, because it
                // says exactly what the encryption covers.
                if state.peer != nil || state.isGroup {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showsEncryption = true
                        } label: {
                            Label(Copy.Chat.encrypted, systemImage: state.isVerified ? "checkmark.shield.fill" : "lock.fill")
                        }
                        .accessibilityIdentifier(
                            state.isGroup ? AccessibilityID.chatEncryption : state.isVerified ? AccessibilityID.chatVerified : ""
                        )
                    }
                }
            }
            .sheet(isPresented: $showsEncryption) {
                EncryptionSheet(text: state.isGroup ? Copy.Groups.encryptionBody : Copy.Chat.encryptionBody(state.title))
            }
            .fullScreenCover(item: $viewing) { photo in
                PhotoViewer(photo: photo)
            }
            .confirmsBlock(of: state.title, isPresented: $confirmsBlock) {
                Task { await model.block() }
            }
            .confirmsDelete($deleting, asking: DeleteQuestion.message) { message in
                Task { await model.delete(message) }
            }
            .alert(Copy.Photo.unreadable, isPresented: $model.photoFailed) {
                Button(Copy.Common.done, role: .cancel) {
                    // The alert closes itself.
                }
            }
            .answersExplicitPhotos(of: model)
            .alert(Copy.Moderation.wordsRefusedTitle, isPresented: $model.wordsRefused) {
                Button(Copy.Common.done, role: .cancel) {
                    // The alert closes itself, and the words stay in the composer.
                }
            } message: {
                Text(state.isRoom ? Copy.Moderation.wordsRefusedInRoom : Copy.Moderation.wordsRefused)
            }
            // A group we left is gone: its thread closes, however the leave came.
            .onChange(of: state.exists) { _, exists in
                if !exists {
                    dismiss()
                }
            }
            .task { await model.appear() }
            .onDisappear(perform: model.disappear)
        }

        /// Asks before deleting `message`, from its bubble's menu.
        private func askToDelete(_ message: ChatMessage) {
            deleting = message
        }
    }

    /// What toggles our reaction to a message, from its menu, a chip or VoiceOver (ADR 2026-10.ehe6).
    @MainActor
    private struct Reacting {
        let model: ChatModel

        /// What toggles our reaction to `message` with an emoji.
        func to(_ message: ChatMessage) -> (String) -> Void {
            { emoji in Task { await model.react(to: message, with: emoji) } }
        }
    }

    /// The thread's title, as Signal sets it: the face, the name, and a line under it, a DM's reach or a group's size. In a
    /// DM or a group it opens the profile or the group's info. The face is decorative, so it reads as the title and line.
    private struct ThreadTitle: View {
        let state: ChatState
        let conversationId: String

        var body: some View {
            if let peer = state.peer {
                NavigationLink(value: Route.peer(peer)) { label }
                    .buttonStyle(.plain)
                    .accessibilityHint(Copy.Chat.profile)
                    .accessibilityShowsLargeContentViewer { Text(state.title) }
                    .accessibilityIdentifier(AccessibilityID.chatProfile)
            } else if state.isGroup {
                NavigationLink(value: Route.groupInfo(conversationId)) { label }
                    .buttonStyle(.plain)
                    .accessibilityHint(Copy.Groups.info)
                    .accessibilityShowsLargeContentViewer { Text(state.title) }
                    .accessibilityIdentifier(AccessibilityID.chatGroupInfo)
            } else {
                label
                    .accessibilityAddTraits(.isHeader)
            }
        }

        private var label: some View {
            HStack(spacing: Layout.small) {
                AvatarView(face: state.face, size: Layout.faceTitle)
                VStack(alignment: .leading, spacing: 0) {
                    Text(state.title)
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryText)
                            .lineLimit(1)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }

        /// A group's size, or whether a DM's peer is in range, in a word; the room has none. The thread says what out of range
        /// means.
        private var subtitle: String? {
            if let count = state.memberCount {
                return Copy.Groups.memberCount(count)
            }
            return state.peer == nil ? nil : state.isLinked ? Copy.Chat.inRange : Copy.Profile.outOfRange
        }
    }

    /// The thread's messages, newest at the bottom, with what the thread says about itself above them. Each day starts
    /// under its date, and a run from one author clusters, as Signal draws it (``MessageClusters``).
    private struct MessageList: View {
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
        @Environment(BlobImageCache.self) private var photos: BlobImageCache?
        @Environment(\.calendar) private var calendar

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
            .onChange(of: state.messages.last?.id) {
                followsBottom = true
                position.scrollTo(edge: .bottom)
            }
            // The edge moves as rows are drawn, a photo decodes, the composer grows or the keyboard rises.
            .onScrollGeometryChange(for: CGFloat.self, of: Self.bottomOffset) { _, _ in
                if followsBottom {
                    position.scrollTo(edge: .bottom)
                }
            }
            .onScrollPhaseChange { _, phase, context in
                switch phase {
                case .tracking, .interacting, .decelerating:
                    followsBottom = false
                case .idle:
                    followsBottom = context.geometry.contentOffset.y >= Self.bottomOffset(context.geometry) - Layout.small
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

        /// The offset that shows the thread's bottom edge above the composer.
        private static func bottomOffset(_ geometry: ScrollGeometry) -> CGFloat {
            geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height
        }

        /// Who sent `message`, as the viewer's bar names them: "You", the author's label, or a DM's peer.
        private func sender(of message: ChatMessage) -> String {
            message.isMine ? Copy.Common.you : message.authorLabel ?? state.title
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

    /// A stranger's thread: Accept instead of the composer, and Block under it for a DM.
    private struct RequestBar: View {
        let title: String
        let explanation: String
        let accept: () -> Void
        let block: (() -> Void)?

        var body: some View {
            VStack(spacing: Layout.small) {
                Text(title)
                    .font(.headline)
                Text(explanation)
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)
                Button(Copy.Chat.accept, action: accept)
                    .prominentButton()
                if let block {
                    Button(Copy.Block.block, role: .destructive, action: block)
                        .foregroundStyle(Palette.critical)
                        .accessibilityIdentifier(AccessibilityID.chatRequestBlock)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            // Opaque, for the same reason as the encryption sheet: the bar's material let the thread through.
            .background(.background.secondary)
        }
    }

    /// The composer's place once everyone else has left a group.
    private struct NobodyLeftBar: View {
        var body: some View {
            Text(Copy.Groups.nobodyLeft)
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.background.secondary)
        }
    }
#endif
