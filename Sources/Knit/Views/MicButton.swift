#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// The composer's mic (knit-next ADR 034's `MicButton`): hold to record, slide up to lock so the finger can lift, slide
    /// back to cancel, and let go to keep the note. VoiceOver's activation records locked, since a press can't be held
    /// through it, and Stop ends it.
    ///
    /// The mic owns the press, so it stays on screen for as long as the finger does: the recording bar takes the field's
    /// place, never the mic's. A view that goes takes its gesture with it, and every recording on Android once ended a
    /// frame after it began that way (ADR 034's trap). Once locked, the mic gives way to Stop; by then the press needs no
    /// end.
    internal struct MicButton: View {
        let model: ChatModel
        let voice: VoiceRecorder
        /// Whether a press is under way, from its first touch, and whether it slid back far enough to cancel.
        @State private var pressing = false
        @State private var cancelled = false
        @Environment(\.layoutDirection) private var direction

        var body: some View {
            Label(Copy.Voice.recordStart, systemImage: "mic.fill")
                .labelStyle(.iconOnly)
                .font(.title2)
                .foregroundStyle(voice.isRecording ? Palette.onAccent : Palette.accent)
                .frame(width: Layout.voiceDisc, height: Layout.voiceDisc)
                .background(voice.isRecording ? Palette.accent : .clear, in: .circle)
                .frame(width: Layout.hitTarget, height: Layout.hitTarget)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged(changed)
                        .onEnded { _ in
                            pressing = false
                            if !cancelled {
                                voice.release()
                            }
                        }
                )
                .sensoryFeedback(.impact(weight: .medium), trigger: voice.isLocked) { was, now in !was && now }
                .sensoryFeedback(.warning, trigger: cancelled) { was, now in !was && now }
                .accessibilityElement()
                .accessibilityLabel(Copy.Voice.recordStart)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    model.startRecording(locked: true)
                }
                .accessibilityIdentifier(AccessibilityID.chatVoiceRecord)
        }

        /// The finger's first touch starts the recording; sliding up locks it, and sliding toward the field's start,
        /// before it locks, cancels it.
        private func changed(_ drag: DragGesture.Value) {
            if !pressing {
                pressing = true
                cancelled = false
                model.startRecording()
            }
            guard voice.isRecording, !voice.isLocked, !cancelled else {
                return
            }
            if drag.translation.height < -Layout.recordingLock {
                voice.lock()
            } else if (direction == .rightToLeft ? drag.translation.width : -drag.translation.width) > Layout.recordingCancel {
                cancelled = true
                voice.cancel()
            }
        }
    }

    /// What the field shows while a note records (`VoiceRecordingBar`): a red dot that swells with the room's loudness, how
    /// long it has run, and how to cancel it, by sliding while held or with a button once locked. It ticks the recorder,
    /// which stops and keeps the note at five minutes.
    internal struct VoiceRecordingBar: View {
        let voice: VoiceRecorder
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            HStack(spacing: Layout.small) {
                // The dot and the clock read as one: "Recording", and how long. The dot alone is too small to reach.
                HStack(spacing: Layout.small) {
                    Circle()
                        .fill(Palette.critical)
                        .frame(width: dot, height: dot)
                        .frame(width: Layout.recordingDot + Layout.recordingDotGrowth)
                    Text(VoicePeaks.clock(milliseconds: voice.elapsedMilliseconds))
                        .monospacedDigit()
                }
                .frame(minHeight: Layout.hitTarget)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Copy.Voice.recording)
                .accessibilityValue(VoicePeaks.clock(milliseconds: voice.elapsedMilliseconds))
                Spacer(minLength: Layout.small)
                if voice.isLocked {
                    Button(action: voice.cancel) {
                        // The label's own color, which a plain button keeps: the coral tint reads 4.4:1 on the field's gray.
                        Label(Copy.Voice.cancel, systemImage: "xmark")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.primary)
                            .frame(width: Layout.hitTarget, height: Layout.hitTarget)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.chatVoiceCancel)
                } else {
                    Label(Copy.Voice.slideToCancel, systemImage: "chevron.backward")
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.chatVoiceRecording)
            .task(id: voice.isRecording) {
                while voice.isRecording, !Task.isCancelled {
                    voice.tick()
                    try? await Task.sleep(for: .milliseconds(VoiceRecorder.tickMilliseconds))
                }
            }
        }

        /// The dot's size: still under Reduce Motion, swelling with the room's loudness otherwise.
        private var dot: CGFloat {
            Layout.recordingDot + (reduceMotion ? 0 : Layout.recordingDotGrowth * voice.level)
        }
    }

    /// The trailing button while a locked note records: Stop, which keeps it (`VoiceStopButton`).
    internal struct StopRecordingButton: View {
        let voice: VoiceRecorder

        var body: some View {
            Button(action: voice.stop) {
                Label(Copy.Voice.stop, systemImage: "stop.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.title)
            }
            .sensoryFeedback(.success, trigger: voice.isRecording) { was, now in was && !now }
            .accessibilityIdentifier(AccessibilityID.chatVoiceStop)
        }
    }

    /// What a press too short to keep says for a moment above the composer (`chat_voice_too_short`'s toast), and to
    /// VoiceOver as it appears.
    internal struct VoiceHint: View {
        /// How long the hint stays, in seconds.
        private static let stays = 2.5

        let voice: VoiceRecorder

        var body: some View {
            Text(Copy.Voice.tooShort)
                .font(.caption)
                .padding(.horizontal, Layout.medium)
                .padding(.vertical, Layout.tight)
                .background(Color(uiColor: .systemBackground), in: .capsule)
                .task {
                    AccessibilityNotification.Announcement(Copy.Voice.tooShort).post()
                    try? await Task.sleep(for: .seconds(Self.stays))
                    if voice.failure == .tooShort {
                        voice.failure = nil
                    }
                }
        }
    }
#endif
