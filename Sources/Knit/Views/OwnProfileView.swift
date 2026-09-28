#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// The user's own profile: what peers read, and this device's id and alias.
    internal struct OwnProfileView: View {
        @State private var model: OwnProfileModel
        @Environment(\.dismiss) private var dismiss

        init(session: AppSession) {
            _model = State(initialValue: OwnProfileModel(session: session))
        }

        var body: some View {
            Form {
                Section {
                    LimitedField(label: Copy.Profile.nameLabel, prompt: model.alias, text: $model.name, remaining: model.nameRemaining)
                        .accessibilityIdentifier(AccessibilityID.profileName)
                    LimitedField(
                        label: Copy.Profile.statusLabel,
                        prompt: Copy.Profile.statusLabel,
                        text: $model.status,
                        remaining: model.statusRemaining
                    )
                    .accessibilityIdentifier(AccessibilityID.profileStatus)
                    Toggle(Copy.Profile.openToChat, isOn: $model.openToChat)
                        .accessibilityIdentifier(AccessibilityID.profileOpenToChat)
                } header: {
                    SectionNote(Copy.Profile.publicSection)
                } footer: {
                    SectionNote(Copy.Profile.openToChatFooter)
                }
                Section {
                    ValueRow(Copy.Profile.aliasLabel, value: model.alias)
                        .accessibilityIdentifier(AccessibilityID.profileAlias)
                    NodeIdRow(nodeId: model.nodeId)
                        .accessibilityIdentifier(AccessibilityID.profileNodeId)
                } header: {
                    SectionNote(Copy.Profile.deviceSection)
                } footer: {
                    SectionNote(Copy.Profile.aliasFooter)
                }
            }
            .navigationTitle(Copy.Profile.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.Common.save) {
                        Task {
                            await model.save()
                            dismiss()
                        }
                    }
                    .disabled(!model.hasChanges)
                    .accessibilityIdentifier(AccessibilityID.profileSave)
                }
            }
            .accessibilityIdentifier(AccessibilityID.profileScreen)
        }
    }

    /// A field that says how much room it has left once it nears its limit.
    private struct LimitedField: View {
        let label: String
        let prompt: String
        @Binding var text: String
        let remaining: Int?

        var body: some View {
            VStack(alignment: .leading, spacing: Layout.hairline) {
                TextField(label, text: $text, prompt: Text(prompt))
                if let remaining {
                    Text(Copy.Profile.remaining(remaining))
                        .font(.caption)
                        .foregroundStyle(Palette.secondaryText)
                }
            }
        }
    }
#endif
