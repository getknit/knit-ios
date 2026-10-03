#if os(iOS)
    import KnitAppCore
    import KnitWire
    import SwiftUI

    /// New message, as a sheet: pick one of the people we know for a DM, or 2 to 7 for a group, then Start chat
    /// (`ContactsScreen` in knit-next).
    internal struct NewMessageView: View {
        @State private var model: NewMessageModel
        @Environment(\.dismiss) private var dismiss
        private let started: (String) -> Void

        /// The picker over `session`, which hands the thread to open to `started`: a DM's node id, or a group's id.
        init(session: AppSession, started: @escaping (String) -> Void) {
            _model = State(initialValue: NewMessageModel(session: session))
            self.started = started
        }

        var body: some View {
            NavigationStack {
                ContactList(model: model)
                    .navigationTitle(Copy.NewMessage.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(Copy.Common.cancel) { dismiss() }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(Copy.NewMessage.start) {
                                Task {
                                    if let conversationId = await model.start() {
                                        started(conversationId)
                                    }
                                }
                            }
                            .disabled(!model.canStart)
                            .accessibilityIdentifier(AccessibilityID.newMessageStart)
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.newMessageScreen)
            }
            // Opaque, as the other sheets are: text over the glass took its contrast from the screen behind.
            .presentationBackground(.background)
        }
    }

    /// The people to pick, with what one and several picks do, or what to do while there is nobody.
    private struct ContactList: View {
        let model: NewMessageModel

        var body: some View {
            List {
                if !model.candidates.isEmpty {
                    Section {
                        ForEach(model.candidates) { contact in
                            let picked = model.isPicked(contact.id)
                            Button {
                                model.toggle(contact.id)
                            } label: {
                                ContactRow(contact: contact, isPicked: picked)
                            }
                            .accessibilityAddTraits(picked ? .isSelected : [])
                            .accessibilityIdentifier(AccessibilityID.newMessageContact(contact.id.string))
                        }
                    } footer: {
                        SectionNote(model.isFull ? Copy.NewMessage.full(GroupInfo.maxMembers) : Copy.NewMessage.explanation)
                    }
                }
            }
            .overlay {
                if model.candidates.isEmpty {
                    ContentUnavailableView(
                        Copy.NewMessage.emptyTitle,
                        systemImage: "person.2",
                        description: Text(Copy.NewMessage.emptyBody)
                    )
                }
            }
        }
    }

    /// One person: whether they are picked, their face and name, and whether they are verified and in range.
    private struct ContactRow: View {
        let contact: Contact
        let isPicked: Bool
        @Environment(\.dynamicTypeSize) private var typeSize

        var body: some View {
            HStack(spacing: Layout.medium) {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(Palette.secondaryText))
                    .accessibilityHidden(true)
                // At the accessibility sizes the face would squeeze the name, which says who.
                if !typeSize.isAccessibilitySize {
                    AvatarView(face: contact.face, size: Layout.faceRow)
                }
                // `Color.primary`, not the hierarchical `.primary`, which the row's button resolves to its tint.
                Text(contact.label)
                    .foregroundStyle(Color.primary)
                if contact.isVerified {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel(Copy.Profile.verified)
                }
                Spacer()
                if contact.isLinked {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(Palette.positive)
                        .accessibilityLabel(Copy.ChatList.inRange)
                }
            }
            .contentShape(.rect)
        }
    }
#endif
