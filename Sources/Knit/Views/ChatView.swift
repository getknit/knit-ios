#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// A thread: the room, a DM or a group, its messages and status lines, a request's Accept, and the composer.
    internal struct ChatView: View {
        @State private var model: ChatModel
        @State private var showsEncryption = false
        @Environment(\.dismiss) private var dismiss

        init(conversationId: String, session: AppSession) {
            _model = State(initialValue: ChatModel(conversationId: conversationId, session: session))
        }

        var body: some View {
            let state = model.state
            MessageList(state: state)
                .safeAreaInset(edge: .bottom) {
                    if state.isRequest {
                        RequestBar(title: state.requestTitle, explanation: state.requestBody) { Task { await model.accept() } }
                    } else if state.nobodyElse {
                        NobodyLeftBar()
                    } else {
                        ComposerBar(model: model)
                    }
                }
                .navigationTitle(state.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
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

    /// The thread's messages, newest at the bottom, with what the thread says about itself above them.
    private struct MessageList: View {
        let state: ChatState

        var body: some View {
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: Layout.small) {
                        ThreadHeader(state: state)
                        ForEach(state.messages) { message in
                            if let notice = message.notice {
                                StatusLineRow(text: notice)
                                    .id(message.id)
                                    .accessibilityIdentifier(AccessibilityID.chatNotice(message.id))
                            } else {
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }
                    }
                    .padding()
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier(AccessibilityID.chatThread)
                .onChange(of: state.messages.last?.id) { _, last in
                    if let last {
                        reader.scrollTo(last, anchor: .bottom)
                    }
                }
            }
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

    /// One message: ours on the right with its tick, theirs on the left, with the author named in the room. The
    /// author's name opens their profile, which is how a DM starts (MVP item 5).
    private struct MessageBubble: View {
        let message: ChatMessage

        var body: some View {
            HStack {
                if message.isMine {
                    Spacer(minLength: Layout.bubbleInset)
                }
                VStack(alignment: message.isMine ? .trailing : .leading, spacing: Layout.hairline) {
                    if let author = message.authorLabel {
                        NavigationLink(value: Route.peer(message.author)) {
                            Text(author)
                                .font(.caption.bold())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                    }
                    Text(message.body)
                        .padding(.horizontal, Layout.medium)
                        .padding(.vertical, Layout.small)
                        .background(fill, in: .rect(cornerRadius: Layout.bubbleCorner))
                        .textSelection(.enabled)
                    Stamp(message: message)
                }
                if !message.isMine {
                    Spacer(minLength: Layout.bubbleInset)
                }
            }
            .accessibilityElement(children: .combine)
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

    /// The composer: the field, what is left near the limit, and Send.
    private struct ComposerBar: View {
        @Bindable var model: ChatModel

        var body: some View {
            VStack(alignment: .trailing, spacing: Layout.tight) {
                if let remaining = model.remaining {
                    Text(Copy.Chat.remaining(remaining))
                        .font(.caption)
                        .foregroundStyle(remaining == 0 ? Palette.critical : Palette.secondaryText)
                }
                HStack(alignment: .bottom) {
                    TextField(Copy.Chat.composerPlaceholder, text: $model.draft, axis: .vertical)
                        .lineLimit(Layout.composerLines)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier(AccessibilityID.chatInput)
                    Button {
                        Task { await model.send() }
                    } label: {
                        Label(Copy.Chat.send, systemImage: "arrow.up.circle.fill")
                            .labelStyle(.iconOnly)
                            .font(.title)
                    }
                    .disabled(!model.canSend)
                    .accessibilityIdentifier(AccessibilityID.chatSend)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, Layout.small)
            // Opaque, like the request bar: the newest message sits against it, and its material let the thread through.
            .background(.background.secondary)
        }
    }

    /// A stranger's thread: Accept instead of the composer.
    private struct RequestBar: View {
        let title: String
        let explanation: String
        let accept: () -> Void

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

    /// What a DM's or a group's encryption covers, and the limit v1 has.
    private struct EncryptionSheet: View {
        let text: String
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                ScrollView {
                    Text(text)
                        .padding()
                }
                .navigationTitle(Copy.Chat.encrypted)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(Copy.Common.done) { dismiss() }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            // Opaque: text over the glass sheet took its contrast from whatever the thread showed behind it.
            .presentationBackground(.background)
        }
    }
#endif
