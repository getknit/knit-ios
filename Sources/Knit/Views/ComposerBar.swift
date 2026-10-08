#if os(iOS)
    import Foundation
    import KnitAppCore
    import SwiftUI

    /// The composer: the photo it holds, the field, what is left near the limit, and Send, or Add photo while there is
    /// nothing to send (`SendAction` in knit-next). From iOS 26 it sits in a glass panel (``SwiftUI/View/glassPanel()``),
    /// with the field and the count on opaque fills of their own.
    internal struct ComposerBar: View {
        @Bindable var model: ChatModel
        let demoPhoto: Data?
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
                        .padding(.horizontal, Layout.small)
                        // The screen's own color, opaque: the background style turns translucent inside the glass.
                        .background(Color(uiColor: .systemBackground), in: .capsule)
                }
                HStack(alignment: .bottom, spacing: Layout.small) {
                    ComposerField(draft: $model.draft)
                        .padding(.horizontal, Layout.medium)
                        .padding(.vertical, Layout.small)
                        .frame(minHeight: Layout.hitTarget)
                        .background(Palette.incomingBubble, in: .rect(cornerRadius: Layout.composerCorner, style: .continuous))
                        .overlay {
                            // On the opaque bar the field needs an edge; inside the glass panel the panel draws one, and
                            // a second ring inside it looked heavy.
                            if !isGlass {
                                RoundedRectangle(cornerRadius: Layout.composerCorner, style: .continuous)
                                    .strokeBorder(.separator)
                            }
                        }
                        .accessibilityIdentifier(AccessibilityID.chatInput)
                    SendButton(model: model, demoPhoto: demoPhoto)
                        .frame(minWidth: Layout.hitTarget, minHeight: Layout.hitTarget)
                        // Add photo turns into Send, and back, with a quick swap rather than a cut.
                        .animation(.snappy, value: model.offersPhoto)
                }
            }
            .padding(Layout.small)
            .glassPanel()
        }

        /// Whether ``SwiftUI/View/glassPanel()`` draws glass here, as it does from iOS 26 unless Reduce Transparency is on.
        private var isGlass: Bool {
            if #available(iOS 26, *) {
                !reduceTransparency
            } else {
                false
            }
        }
    }

    /// The composer's field, a line tall until the words need more, then growing a line at a time to
    /// ``Layout/composerLines``' last. On iOS 27 a multiline field draws three lines tall, empty or not, under any range of
    /// limits; a whole-number limit under three holds it to one or two. So its limit is the words' own count of lines,
    /// read off a hidden copy set in the same font and width.
    private struct ComposerField: View {
        @Binding var draft: String
        /// The words' height, and one line's, as the hidden copies measure them.
        @State private var height: CGFloat = 0
        @State private var line: CGFloat = 0

        var body: some View {
            TextField(Copy.Chat.composerPlaceholder, text: $draft, axis: .vertical)
                .lineLimit(lines)
                .background(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        // A last line break opens a line the text alone does not measure.
                        Text(verbatim: draft.hasSuffix("\n") || draft.isEmpty ? draft + " " : draft)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
                        Text(verbatim: " ")
                            .onGeometryChange(for: CGFloat.self, of: \.size.height) { line = $0 }
                    }
                    .hidden()
                    .accessibilityHidden(true)
                }
        }

        /// How many lines the words take, from one to the composer's most.
        private var lines: Int {
            let measured = line > 0 ? Int((height / line).rounded()) : 1
            return min(max(measured, Layout.composerLines.lowerBound), Layout.composerLines.upperBound)
        }
    }

    /// The composer's button: Send, or Add photo while there is nothing to send. A send still under way after a moment
    /// shows Knit's stitches in place of the arrow, chiefly the first in a while, which waits for the text model to load.
    private struct SendButton: View {
        /// How long a send runs before the stitches show, in milliseconds, so a quick one does not flash them
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
                .transition(.scale(scale: Layout.swapScale).combined(with: .opacity))
                .accessibilityIdentifier(AccessibilityID.chatAddPhoto)
            } else {
                Button {
                    Task { await model.send() }
                } label: {
                    // The arrow keeps its room while the stitches cover it, so the composer does not shift.
                    Label(Copy.Chat.send, systemImage: "arrow.up.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title)
                        .opacity(spinning ? 0 : 1)
                        .overlay {
                            if spinning {
                                StitchIndicator()
                            }
                        }
                }
                .disabled(!model.canSend)
                .transition(.scale(scale: Layout.swapScale).combined(with: .opacity))
                .sensoryFeedback(.impact(weight: .light), trigger: model.isSending) { was, now in !was && now }
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

        /// Whether the stitches show: the send is still under way, and has been for a moment.
        private var spinning: Bool {
            slow && model.isSending
        }

        private func choose(_ data: Data?) {
            Task { await model.choosePhoto(data) }
        }
    }
#endif
