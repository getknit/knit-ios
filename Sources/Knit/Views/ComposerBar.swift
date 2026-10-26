#if os(iOS)
    import Foundation
    import KnitAppCore
    import SwiftUI

    /// The composer: the people an "@" offers, the quote it holds, the photo or voice note it holds, the field, what is
    /// left near the limit, the mic in a build with voice notes, and Send, or Add photo while there is nothing to send
    /// (`SendAction` in knit-next). While a note records, the recording bar takes the field's place (knit-next ADR 034).
    /// From iOS 26 it sits in a glass panel (``SwiftUI/View/glassPanel()``), with the quote, the field and the count on
    /// opaque fills of their own. A reply started from a message gives the field focus (ADR 2026-10.mn29).
    internal struct ComposerBar: View {
        @Bindable var model: ChatModel
        let demoPhoto: Data?
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @State private var typing = false

        /// The photo the composer holds, or a spinner while a picked one is made ready to send.
        @ViewBuilder private var held: some View {
            if model.preparingPhoto {
                ProgressView()
                    .frame(width: Layout.stagedPhoto, height: Layout.stagedPhoto)
                    .accessibilityLabel(Copy.Attachments.preparingPhoto)
            } else if let staged = model.staged {
                StagedPhotoView(staged: staged, remove: model.removePhoto)
            }
        }

        /// The quote and the photo the composer holds, each only while there is something to hold: an empty full-width
        /// frame here kept the thread above relaying itself at the largest text size, and the accessibility audit never
        /// finished.
        @ViewBuilder private var holding: some View {
            let candidates = model.mentionCandidates
            if !candidates.isEmpty {
                MentionPicker(candidates: candidates, pick: model.mention)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let replying = model.replying {
                ReplyBar(quote: replying.quote, cancel: model.cancelReply)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.preparingPhoto || model.staged != nil {
                held
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let note = model.voice?.staged {
                StagedVoiceView(staged: note, remove: model.removeVoice)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let voice = model.voice, voice.failure == .tooShort {
                VoiceHint(voice: voice)
            }
        }

        var body: some View {
            VStack(alignment: .trailing, spacing: Layout.tight) {
                holding
                if let remaining = model.remaining {
                    Text(Copy.Chat.remaining(remaining))
                        .font(.caption)
                        .foregroundStyle(remaining == 0 ? Palette.critical : Palette.secondaryText)
                        .padding(.horizontal, Layout.small)
                        // The screen's own color, opaque: the background style turns translucent inside the glass.
                        .background(Color(uiColor: .systemBackground), in: .capsule)
                }
                row
            }
            .padding(Layout.small)
            .glassPanel()
            .onChange(of: model.repliesStarted) {
                typing = true
            }
        }

        /// The field, or the recording bar in its place; the mic; and the trailing button.
        private var row: some View {
            HStack(alignment: .bottom, spacing: Layout.small) {
                Group {
                    if let voice = model.voice, voice.isRecording {
                        VoiceRecordingBar(voice: voice)
                    } else {
                        ComposerField(model: model, typing: $typing)
                    }
                }
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
                if let voice = model.voice, model.offersVoice {
                    MicButton(model: model, voice: voice)
                }
                trailing
                    .frame(minWidth: Layout.hitTarget, minHeight: Layout.hitTarget)
                    // Add photo turns into Send, and back, with a quick swap rather than a cut.
                    .animation(.snappy, value: model.offersPhoto)
            }
        }

        /// The trailing button: Send or Add photo; nothing while a held press records, so the thumb has the mic alone; and
        /// Stop once the recording locks (`ChatScreen.kt:4747-4762`).
        @ViewBuilder private var trailing: some View {
            if let voice = model.voice, voice.isRecording {
                if voice.isLocked {
                    StopRecordingButton(voice: voice)
                } else {
                    Color.clear
                        .accessibilityHidden(true)
                }
            } else {
                SendButton(model: model, demoPhoto: demoPhoto)
            }
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

    /// The composer's field (``ComposerTextView``), with the placeholder over it while it is empty, which the text view does
    /// not draw. VoiceOver reads the placeholder as the field's label.
    private struct ComposerField: View {
        let model: ChatModel
        @Binding var typing: Bool

        var body: some View {
            ComposerTextView(model: model, draft: model.draft, selection: model.selection, chips: model.chips, focused: $typing)
                .overlay(alignment: .topLeading) {
                    if model.draft.isEmpty {
                        Text(Copy.Chat.composerPlaceholder)
                            .foregroundStyle(Palette.secondaryText)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
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
