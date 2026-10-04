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
        /// The messages whose hidden photo was tapped to show, while the thread is open (ADR 2026-10.rpmq).
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
            MessageList(state: state, revealed: revealed, reveal: { revealed.insert($0) }, view: { viewing = $0 })
                .safeAreaInset(edge: .bottom) {
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
                        ThreadTitle(title: state.title, face: state.face)
                    }
                    if let peer = state.peer {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Button {
                                showsEncryption = true
                            } label: {
                                Label(Copy.Chat.encrypted, systemImage: state.isVerified ? "checkmark.shield.fill" : "lock.fill")
                            }
                            .accessibilityIdentifier(state.isVerified ? AccessibilityID.chatVerified : "")
                            NavigationLink(value: Route.peer(peer)) {
                                Label(Copy.Chat.profile, systemImage: "person.crop.circle")
                            }
                            .accessibilityIdentifier(AccessibilityID.chatProfile)
                        }
                    } else if state.isGroup {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Button {
                                showsEncryption = true
                            } label: {
                                Label(Copy.Chat.encrypted, systemImage: "lock.fill")
                            }
                            .accessibilityIdentifier(AccessibilityID.chatEncryption)
                            NavigationLink(value: Route.groupInfo(model.conversationId)) {
                                Label(Copy.Groups.info, systemImage: "info.circle")
                            }
                            .accessibilityIdentifier(AccessibilityID.chatGroupInfo)
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
                .alert(Copy.Photo.unreadable, isPresented: $model.photoFailed) {
                    Button(Copy.Common.done, role: .cancel) {
                        // The alert closes itself.
                    }
                }
                .answersExplicitPhotos(of: model)
                // A group we left is gone: its thread closes, however the leave came.
                .onChange(of: state.exists) { _, exists in
                    if !exists {
                        dismiss()
                    }
                }
                .task { await model.appear() }
                .onDisappear(perform: model.disappear)
        }
    }

    /// The thread's face beside its title. The face is decorative, so the title reads as the title alone.
    private struct ThreadTitle: View {
        let title: String
        let face: Face

        var body: some View {
            HStack(spacing: Layout.small) {
                AvatarView(face: face, size: Layout.faceTitle)
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }

    /// The thread's messages, newest at the bottom, with what the thread says about itself above them.
    private struct MessageList: View {
        let state: ChatState
        /// The messages whose hidden photo was tapped to show.
        let revealed: Set<String>
        /// Shows a message's hidden photo.
        let reveal: (String) -> Void
        /// Opens a message's photo full screen.
        let view: (ViewedPhoto) -> Void
        /// Where the thread rests: at its bottom edge, below the newest message's padding. A position on the edge stays on
        /// it as a row grows, where one scrolled to the newest message's id did not: a photo holds a spinner's place until
        /// it decodes, then stands up to a hundred points taller, which left its stamp and tick under the composer.
        @State private var position = ScrollPosition(edge: .bottom)

        var body: some View {
            ScrollView {
                LazyVStack(spacing: Layout.small) {
                    ThreadHeader(state: state)
                    ForEach(state.messages) { message in
                        if let notice = message.notice {
                            StatusLineRow(text: notice)
                                .accessibilityIdentifier(AccessibilityID.chatNotice(message.id))
                        } else {
                            MessageBubble(
                                message: message,
                                revealed: revealed.contains(message.id),
                                reveal: { reveal(message.id) },
                                open: { view(.chat($0, sender: sender(of: message))) }
                            )
                        }
                    }
                }
                .padding()
            }
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier(AccessibilityID.chatThread)
            .onChange(of: state.messages.last?.id) {
                position.scrollTo(edge: .bottom)
            }
        }

        /// Who sent `message`, as the viewer's bar names them: "You", the author's label, or a DM's peer.
        private func sender(of message: ChatMessage) -> String {
            message.isMine ? Copy.Common.you : message.authorLabel ?? state.title
        }
    }

    /// The room's notice, a group's size, a DM's reach, and what an empty thread holds.
    private struct ThreadHeader: View {
        let state: ChatState

        var body: some View {
            if state.isRoom {
                Notice(symbol: "person.3", text: Copy.Chat.roomNotice)
                if state.messages.isEmpty {
                    Notice(symbol: "hand.wave", text: Copy.Chat.roomEmpty)
                }
            } else if let count = state.memberCount {
                Text(Copy.Groups.memberCount(count))
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
            } else {
                Text(state.isLinked ? Copy.Chat.inRange : Copy.Chat.outOfRange)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                if state.messages.isEmpty {
                    Notice(symbol: "lock", text: Copy.Chat.directEmpty(state.title))
                }
            }
        }
    }

    /// A group's status line: an event, such as a member leaving, centered between the messages.
    private struct StatusLineRow: View {
        let text: String

        var body: some View {
            Text(text)
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Layout.tight)
        }
    }

    /// A line the thread says about itself rather than a message.
    private struct Notice: View {
        let symbol: String
        let text: String

        var body: some View {
            Label(text, systemImage: symbol)
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Layout.tight)
        }
    }

    /// One message: ours on the right with its tick, theirs on the left, with the author's face and name in the room and
    /// a group. The author's face and name open their profile, which is how a DM starts (MVP item 5). A photo sits above
    /// the words, and opens full screen, unless the content filter hides it until a tap.
    private struct MessageBubble: View {
        let message: ChatMessage
        /// Whether the message's hidden photo was tapped to show.
        let revealed: Bool
        /// Shows it.
        let reveal: () -> Void
        /// Opens the message's photo.
        let open: (ChatAttachment) -> Void
        @Environment(\.dynamicTypeSize) private var typeSize
        @Environment(PhotoScreening.self) private var screening: PhotoScreening?

        var body: some View {
            HStack(alignment: .bottom, spacing: Layout.small) {
                if message.isMine {
                    Spacer(minLength: Layout.bubbleInset)
                }
                // At the accessibility sizes the face would take the bubble's room; the name above it says who.
                if let face = message.authorFace, !typeSize.isAccessibilitySize {
                    NavigationLink(value: Route.peer(message.author)) {
                        AvatarView(face: face, size: Layout.faceBubble)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHidden(true)
                }
                BubbleContent(message: message, covered: covered, reveal: reveal, open: open)
                if !message.isMine {
                    Spacer(minLength: Layout.bubbleInset)
                }
            }
            // A message reads as one element. Its photo stays a button for a tap, and VoiceOver opens it by name: the
            // photo as an element of its own left the author's name its own element too, a hit area too small to audit.
            .accessibilityElement(children: .combine)
            .accessibilityActions {
                if let photo {
                    if covered {
                        Button(Copy.Moderation.showPhoto, action: reveal)
                    } else {
                        Button(Copy.Attachments.viewPhoto) { open(photo) }
                    }
                }
            }
            .accessibilityValue(covered ? Copy.Moderation.hiddenPhotoValue : "")
            .accessibilityIdentifier(photo.map { _ in AccessibilityID.chatPhoto(message.id) } ?? "")
        }

        /// The message's photo, which opens full screen, or `nil` when it carries none.
        private var photo: ChatAttachment? {
            message.attachment.flatMap { $0.kind == .photo ? $0 : nil }
        }

        /// Whether the content filter hides the photo now: screened explicit, someone else's, and not tapped to show.
        private var covered: Bool {
            !revealed && photo.map { screening?.isHiding($0, isMine: message.isMine) == true } == true
        }
    }

    /// A message's column: the author's name in the room and a group, which opens their profile, its photo, its words,
    /// and its stamp.
    private struct BubbleContent: View {
        let message: ChatMessage
        /// Whether the photo hides until a tap.
        let covered: Bool
        let reveal: () -> Void
        let open: (ChatAttachment) -> Void

        var body: some View {
            VStack(alignment: message.isMine ? .trailing : .leading, spacing: Layout.hairline) {
                if let author = message.authorLabel {
                    NavigationLink(value: Route.peer(message.author)) {
                        Text(author)
                            .font(.caption.bold())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
                if let attachment = message.attachment {
                    AttachmentView(attachment: attachment, isMine: message.isMine, covered: covered, reveal: reveal) { open(attachment) }
                }
                if !message.body.isEmpty {
                    Text(message.body)
                        .padding(.horizontal, Layout.medium)
                        .padding(.vertical, Layout.small)
                        .background(fill, in: .rect(cornerRadius: Layout.bubbleCorner))
                        .textSelection(.enabled)
                }
                Stamp(message: message)
            }
        }

        private var fill: AnyShapeStyle {
            message.isMine ? AnyShapeStyle(.tint.opacity(Layout.ownBubbleOpacity)) : AnyShapeStyle(.fill.tertiary)
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
