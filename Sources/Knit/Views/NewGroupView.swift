#if os(iOS)
    import KnitAppCore
    import KnitWire
    import SwiftUI

    /// The new-group picker: pick 2 to 7 of the people we know, then Start group (`ContactsScreen` in knit-next, which
    /// starts a DM from one pick; the iPhone starts DMs from a profile).
    internal struct NewGroupView: View {
        @State private var model: NewGroupModel
        private let created: (String) -> Void

        /// The picker over `session`, which hands the new group's id to `created`.
        init(session: AppSession, created: @escaping (String) -> Void) {
            _model = State(initialValue: NewGroupModel(session: session))
            self.created = created
        }

        var body: some View {
            List {
                Section {
                    if model.candidates.isEmpty {
                        Text(Copy.Groups.pickerEmpty)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    ForEach(model.candidates) { candidate in
                        let picked = model.isPicked(candidate.id)
                        Button {
                            model.toggle(candidate.id)
                        } label: {
                            CandidateRow(candidate: candidate, isPicked: picked)
                        }
                        .accessibilityAddTraits(picked ? .isSelected : [])
                        .accessibilityIdentifier(AccessibilityID.newGroupMember(candidate.id.string))
                    }
                } footer: {
                    SectionNote(model.isFull ? Copy.Groups.full(GroupInfo.maxMembers) : Copy.Groups.pickerExplanation)
                }
            }
            .navigationTitle(Copy.Groups.newGroup)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.Groups.create) {
                        Task {
                            if let groupId = await model.create() {
                                created(groupId)
                            }
                        }
                    }
                    .disabled(!model.canCreate)
                    .accessibilityIdentifier(AccessibilityID.newGroupCreate)
                }
            }
            .accessibilityIdentifier(AccessibilityID.newGroupScreen)
        }
    }

    /// One person: whether they are picked, their name, and whether they are verified and in range.
    private struct CandidateRow: View {
        let candidate: GroupCandidate
        let isPicked: Bool

        var body: some View {
            HStack(spacing: Layout.medium) {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(Palette.secondaryText))
                    .accessibilityHidden(true)
                Text(candidate.label)
                    .foregroundStyle(.primary)
                if candidate.isVerified {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel(Copy.Profile.verified)
                }
                Spacer()
                if candidate.isLinked {
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
