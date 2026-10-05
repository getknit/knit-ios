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
                Group {
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
                // A container, so the audit knows where the bar starts (`AuditPolicy`).
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AccessibilityID.chatBottomBar)
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
            // The bar's whole height, so a tap just under the face opens the profile. iOS takes a tap on the bar's empty strip
            // there as a scroll to the thread's top.
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
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
