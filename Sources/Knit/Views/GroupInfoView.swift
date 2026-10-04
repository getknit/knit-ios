#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// Group info: who is in the group, Rename and Leave (`GroupDetailsScreen` in knit-next, less the photo).
    internal struct GroupInfoView: View {
        @State private var model: GroupInfoModel
        @State private var renaming = false
        @State private var confirmsLeave = false
        private let left: () -> Void

        /// Group `groupId`'s info over `session`. `left` runs once the group is gone, so its screens close.
        init(groupId: String, session: AppSession, left: @escaping () -> Void) {
            _model = State(initialValue: GroupInfoModel(groupId: groupId, session: session))
            self.left = left
        }

        var body: some View {
            let state = model.state
            Form {
                Section {
                    GroupHeader(state: state)
                        .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(state.members) { member in
                        MemberRow(member: member)
                            .accessibilityIdentifier(AccessibilityID.groupMember(member.id))
                    }
                } header: {
                    SectionNote(Copy.Groups.members)
                }
                Section {
                    Button(Copy.Groups.rename) {
                        model.beginRename()
                        renaming = true
                    }
                    .accessibilityIdentifier(AccessibilityID.groupRename)
                    Button(Copy.Groups.leave, role: .destructive) {
                        confirmsLeave = true
                    }
                    .foregroundStyle(Palette.critical)
                    .accessibilityIdentifier(AccessibilityID.groupLeave)
                }
            }
            .navigationTitle(Copy.Groups.info)
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier(AccessibilityID.groupInfoScreen)
            .sheet(isPresented: $renaming) {
                RenameSheet(model: model)
            }
            .confirmationDialog(Copy.Groups.leaveTitle, isPresented: $confirmsLeave, titleVisibility: .visible) {
                Button(Copy.Groups.leaveAction, role: .destructive) {
                    Task { await model.leave() }
                }
            } message: {
                Text(Copy.Groups.leaveBody)
            }
            // However the group went, here or from somewhere else, its screens close.
            .onChange(of: state.exists) { _, exists in
                if !exists {
                    left()
                }
            }
        }
    }

    /// The group's face, its title and how many are in it, centered on the page as Signal heads a group.
    private struct GroupHeader: View {
        let state: GroupInfoState

        var body: some View {
            VStack(spacing: Layout.tight) {
                AvatarView(face: state.face, size: Layout.faceProfile)
                    .padding(.bottom, Layout.small)
                Text(state.title)
                    .font(.title2.bold())
                Text(Copy.Groups.memberCount(state.memberCount))
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
        }
    }

    /// One member: their face and name, whether they are verified and in range, and the way to their profile.
    private struct MemberRow: View {
        let member: GroupMemberRow

        var body: some View {
            if let peer = member.peer {
                NavigationLink(value: Route.peer(peer)) {
                    MemberLabel(member: member)
                }
            } else {
                MemberLabel(member: member)
            }
        }
    }

    private struct MemberLabel: View {
        let member: GroupMemberRow
        @Environment(\.dynamicTypeSize) private var typeSize

        var body: some View {
            HStack(spacing: Layout.small) {
                // At the accessibility sizes the face would squeeze the name, which says who.
                if !typeSize.isAccessibilitySize {
                    AvatarView(face: member.face, size: Layout.faceRow)
                        .padding(.trailing, Layout.tight)
                }
                Text(member.label)
                if member.isVerified {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel(Copy.Profile.verified)
                }
                Spacer()
                if member.isLinked {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(Palette.positive)
                        .accessibilityLabel(Copy.ChatList.inRange)
                }
            }
        }
    }

    /// The new name, from the title the group shows now, cut at the limit as it is typed.
    private struct RenameSheet: View {
        @Bindable var model: GroupInfoModel
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                Form {
                    TextField(Copy.Groups.nameLabel, text: $model.draftName)
                }
                .navigationTitle(Copy.Groups.rename)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(Copy.Common.cancel) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(Copy.Groups.renameAction) {
                            Task {
                                if await model.rename() {
                                    dismiss()
                                }
                            }
                        }
                        .disabled(!model.canRename)
                    }
                }
            }
            .presentationDetents([.medium, .large])
            // Opaque, as the encryption sheet is: text over the glass took its contrast from the screen behind.
            .presentationBackground(.background)
        }
    }
#endif
