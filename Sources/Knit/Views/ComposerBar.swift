#if os(iOS)
    import Foundation
    import KnitAppCore
    import SwiftUI

    /// The composer: the photo it holds, the field, what is left near the limit, and Send, or Add photo while there is
    /// nothing to send (`SendAction` in knit-next).
    internal struct ComposerBar: View {
        @Bindable var model: ChatModel
        let demoPhoto: Data?

        var body: some View {
            VStack(alignment: .trailing, spacing: Layout.tight) {
                if let staged = model.staged {
                    StagedPhotoView(staged: staged, remove: model.removePhoto)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
                    SendButton(model: model, demoPhoto: demoPhoto)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, Layout.small)
            // Opaque, like the request bar: the newest message sits against it, and its material let the thread through.
            .background(.background.secondary)
        }
    }

    /// The composer's button: Send, or Add photo while there is nothing to send.
    private struct SendButton: View {
        let model: ChatModel
        let demoPhoto: Data?

        var body: some View {
            if model.offersPhoto {
                PhotoPickerButton(demo: demoPhoto, picked: choose) {
                    Label(Copy.Attachments.addPhoto, systemImage: "photo.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title)
                }
                .accessibilityIdentifier(AccessibilityID.chatAddPhoto)
            } else {
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

        private func choose(_ data: Data?) {
            Task { await model.choosePhoto(data) }
        }
    }
#endif
