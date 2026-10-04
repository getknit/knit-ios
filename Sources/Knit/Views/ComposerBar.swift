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

    /// The composer's button: Send, or Add photo while there is nothing to send. A send still under way after a moment
    /// shows a spinner in place of the arrow, chiefly the first in a while, which waits for the text model to load.
    private struct SendButton: View {
        /// How long a send runs before the spinner shows, in milliseconds, so a quick one does not flash it
        /// (`SEND_SPINNER_DELAY_MS`).
        private static let spinnerDelay = 300

        let model: ChatModel
        let demoPhoto: Data?
        /// Whether the send under way has outlasted ``spinnerDelay``.
        @State private var slow = false

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
                    // The arrow keeps its room while the spinner covers it, so the composer does not shift.
                    Label(Copy.Chat.send, systemImage: "arrow.up.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title)
                        .opacity(spinning ? 0 : 1)
                        .overlay {
                            if spinning {
                                ProgressView()
                            }
                        }
                }
                .disabled(!model.canSend)
                .accessibilityLabel(spinning ? Copy.Chat.sending : Copy.Chat.send)
                .accessibilityIdentifier(AccessibilityID.chatSend)
                .task(id: model.isSending) {
                    slow = false
                    guard model.isSending, (try? await Task.sleep(for: .milliseconds(Self.spinnerDelay))) != nil else {
                        return
                    }
                    slow = true
                }
            }
        }

        /// Whether the spinner shows: the send is still under way, and has been for a moment.
        private var spinning: Bool {
            slow && model.isSending
        }

        private func choose(_ data: Data?) {
            Task { await model.choosePhoto(data) }
        }
    }
#endif
