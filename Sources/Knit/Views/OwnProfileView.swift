#if os(iOS)
    import Foundation
    import KnitAppCore
    import SwiftUI

    /// The user's own profile: the photo and what peers read, and this device's id and alias.
    internal struct OwnProfileView: View {
        @State private var model: OwnProfileModel
        @Environment(\.dismiss) private var dismiss
        private let demoPhoto: Data?

        /// The profile over `session`, cropping photos through `codec` and checking them with `screening`. `demoPhoto`
        /// stands in for the photo library.
        init(session: AppSession, codec: any ImageCodec, screening: PhotoScreening, demoPhoto: Data?) {
            _model = State(initialValue: OwnProfileModel(session: session, codec: codec, screening: screening))
            self.demoPhoto = demoPhoto
        }

        var body: some View {
            Form {
                PhotoSection(model: model, demoPhoto: demoPhoto)
                PublicSection(model: model)
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
            // Pushed, not presented: the system's picker may still be closing as the photo decodes, and SwiftUI drops a
            // presentation that starts while another is going.
            .navigationDestination(isPresented: $model.isCropping) {
                if let source = model.cropSource as? DeviceImage {
                    AvatarCropView(source: source, cancel: model.cancelCrop) { framing in
                        Task { await model.cropPhoto(framing) }
                    }
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationBarBackButtonHidden()
                }
            }
            .alert(Copy.Photo.unreadable, isPresented: $model.photoFailed) {
                Button(Copy.Common.done, role: .cancel) {
                    // The alert closes itself.
                }
            }

            .accessibilityIdentifier(AccessibilityID.profileScreen)
        }
    }

    /// The name, status and open-to-chat flag peers read.
    private struct PublicSection: View {
        @Bindable var model: OwnProfileModel

        var body: some View {
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
        }
    }

    /// The photo over the buttons that choose and remove it, which change nothing until Save. The photo sits in the
    /// section's header, apart from the buttons' rows: the accessibility audit read a label centered under the disc
    /// against the disc's color, and a monogram's pastel failed it (ADR 2026-10.sepc).
    private struct PhotoSection: View {
        let model: OwnProfileModel
        let demoPhoto: Data?

        var body: some View {
            Section {
                PhotoPickerButton(demo: demoPhoto, picked: choose) {
                    Text(model.hasPhoto ? Copy.Profile.changePhoto : Copy.Profile.choosePhoto)
                }
                .accessibilityIdentifier(AccessibilityID.profileChoosePhoto)
                if model.hasPhoto {
                    Button(Copy.Profile.removePhoto, action: model.removePhoto)
                        .foregroundStyle(Palette.critical)
                        .accessibilityIdentifier(AccessibilityID.profileRemovePhoto)
                }
            } header: {
                AvatarView(face: model.face, size: Layout.faceProfile, unsaved: model.unsavedPhoto)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, Layout.small)
            } footer: {
                // A refusal says so here rather than in an alert: it lands as the cropper closes, and SwiftUI drops an
                // alert that starts while the cropper's page is still going (ADR 2026-10.spcy).
                if model.photoRefused {
                    Text(Copy.Moderation.profileRefusal)
                        .font(.footnote)
                        .foregroundStyle(Palette.critical)
                        .accessibilityIdentifier(AccessibilityID.profilePhotoRefused)
                } else {
                    SectionNote(Copy.Profile.photoFooter)
                }
            }
        }

        private func choose(_ data: Data?) {
            Task { await model.choosePhoto(data) }
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
