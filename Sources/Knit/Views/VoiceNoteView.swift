#if os(iOS)
    import KnitAppCore
    import KnitStore
    import KnitWire
    import SwiftUI

    extension EnvironmentValues {
        /// The session a voice bubble plays through, which opens a sealed note in memory, or `nil` in a build without
        /// voice notes. The bubble reads the one player's place from it, so moving bars reconfigure no cell (ADR
        /// 2026-10.pkbu, as `PhotoArrivals`).
        @Entry var voiceSession: AppSession?
    }

    /// A voice note in its bubble (knit-next ADR 034's `VoiceNoteRow`): play, the waveform, and its length, or how far it
    /// has played. Until its bytes are here, it waits as a photo waits, with the same ring while they stream in.
    internal struct VoiceNoteView: View {
        let attachment: ChatAttachment
        let isMine: Bool
        @Environment(\.voiceSession) private var session

        var body: some View {
            if attachment.isHeld, let session {
                let playback = session.voiceNotes?.playback
                VStack(alignment: .leading, spacing: Layout.tight) {
                    VoicePlayerRow(
                        lengthMs: attachment.voice?.durationMs,
                        peaks: attachment.voice?.peaks,
                        now: playback?.position(of: attachment.hash),
                        isMine: isMine,
                        reachesPlay: false,
                        toggle: { Task { await session.toggleVoice(attachment) } },
                        seek: { session.seekVoice(attachment, to: $0) }
                    )
                    if playback?.unplayable.contains(attachment.hash) == true {
                        Text(Copy.Voice.unplayable)
                            .font(.caption)
                            .foregroundStyle(isMine ? AnyShapeStyle(Palette.onOwnBubble) : AnyShapeStyle(Palette.secondaryText))
                    }
                }
                .padding(.horizontal, Layout.medium)
                .padding(.vertical, Layout.small)
                .background(isMine ? Palette.ownBubble : Palette.incomingBubble, in: .rect(cornerRadius: Layout.bubbleCorner))
            } else {
                WaitingVoice(hash: attachment.hash)
            }
        }
    }

    /// A voice note still on its way, in a row the player's width (`VoiceNote.kt:204-228`): a ring over how much of how
    /// much is in while a link brings it, or a still arrow from a sender that declared no size, and until then Knit's
    /// stitches, an hourglass after ``Layout/photoPatience`` seconds, beside what it waits for, as a photo waits.
    private struct WaitingVoice: View {
        let hash: BlobHash
        @State private var stalled = false
        @Environment(PhotoArrivals.self) private var arrivals: PhotoArrivals?

        var body: some View {
            let arrival = arrivals?[hash]
            HStack(spacing: Layout.medium) {
                Group {
                    if let arrival {
                        if let fraction = arrival.fraction {
                            ArrivalRing(fraction: fraction)
                        } else {
                            Image(systemName: "arrow.down.circle")
                        }
                    } else if stalled {
                        Image(systemName: "hourglass")
                    } else {
                        StitchIndicator()
                    }
                }
                .frame(width: Layout.voiceDisc, height: Layout.voiceDisc)
                .accessibilityHidden(true)
                Text(arrival?.caption ?? Copy.Voice.waiting)
                    .font(.caption)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Layout.medium)
            .padding(.vertical, Layout.small)
            .frame(width: Layout.photoWidth, alignment: .leading)
            .background(Palette.incomingBubble, in: .rect(cornerRadius: Layout.bubbleCorner))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(arrival == nil ? AccessibilityID.chatAttachmentWaiting : AccessibilityID.chatAttachmentArriving)
            .task(id: hash) {
                guard !stalled else {
                    return
                }
                try? await Task.sleep(for: .seconds(Layout.photoPatience))
                if !Task.isCancelled {
                    stalled = true
                }
            }
        }
    }

    /// The voice note the composer holds (`VoiceNotePreview`): the bubble's row, played from memory before anything is
    /// stored, and the button that takes it out.
    internal struct StagedVoiceView: View {
        let staged: StagedVoice
        let remove: () -> Void
        @Environment(\.voiceSession) private var session

        var body: some View {
            HStack(spacing: Layout.small) {
                VoicePlayerRow(
                    lengthMs: staged.durationMilliseconds,
                    peaks: staged.peaks,
                    now: session?.voiceNotes?.playback.position(of: staged.hash),
                    isMine: false,
                    toggle: { Task { await session?.toggleVoice(staged) } },
                    seek: { session?.seekVoice(staged, to: $0) }
                )
                Button(action: remove) {
                    Label(Copy.Voice.remove, systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .foregroundStyle(Palette.secondaryText)
                        .frame(width: Layout.hitTarget, height: Layout.hitTarget)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.chatVoiceRemove)
            }
            .padding(.leading, Layout.medium)
            .background(Palette.incomingBubble, in: .rect(cornerRadius: Layout.composerCorner, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.chatVoiceStaged)
        }
    }

    /// Play, the waveform and the clock (`VoiceNoteRow`'s row): the bars fill as the note plays, a tap on them moves the
    /// loaded note there, and the clock shows how far it has played, or its length when it isn't playing. A note with no
    /// length yet shows 0:00 and can't be moved, and one with no waveform draws flat bars, as on Android.
    internal struct VoicePlayerRow: View {
        let lengthMs: Int?
        let peaks: [UInt8]?
        let now: VoicePlayback.NowPlaying?
        let isMine: Bool
        /// Whether VoiceOver reaches the play button itself: in the composer. A bubble's message offers Play and Pause
        /// among its own actions, so its button would only repeat them in the message's one label.
        var reachesPlay = true
        let toggle: () -> Void
        let seek: (Double) -> Void

        var body: some View {
            let length = lengthMs ?? 0
            let place = now?.position ?? 0
            HStack(spacing: Layout.small) {
                Button(action: toggle) {
                    Image(systemName: now?.playing == true ? "pause.fill" : "play.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isMine ? Palette.ownBubble : Palette.onAccent)
                        .frame(width: Layout.voiceDisc, height: Layout.voiceDisc)
                        .background(isMine ? Palette.onOwnBubble : Palette.accent, in: .circle)
                        .frame(width: Layout.hitTarget, height: Layout.hitTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(now?.playing == true ? Copy.Voice.pause : Copy.Voice.play)
                .accessibilityIdentifier(AccessibilityID.chatVoicePlay)
                .accessibilityHidden(!reachesPlay)
                Waveform(
                    heights: VoicePeaks.heights(peaks),
                    played: length > 0 && now != nil ? min(Double(place) / Double(length), 1) : 0,
                    tint: isMine ? Palette.onOwnBubble : Palette.accent,
                    seek: length > 0 ? seek : nil
                )
                .frame(height: Layout.voiceWaveform)
                .accessibilityHidden(true)
                // The clock names the note for VoiceOver, with what it shows: "Voice message, 0:42", or "…, at 0:07".
                let shown = VoicePeaks.clock(milliseconds: place > 0 ? place : length)
                let whole = VoicePeaks.clock(milliseconds: length)
                Text(shown)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(isMine ? AnyShapeStyle(Palette.onOwnBubble) : AnyShapeStyle(.primary))
                    .accessibilityLabel(place > 0 ? Copy.Voice.playing(length: whole, at: shown) : Copy.Voice.described(length: whole))
            }
            .frame(minWidth: Layout.photoWidth)
        }
    }

    /// A voice note's bars, played ones in full and the rest faint (`Waveform` in `VoiceNote.kt`), mirrored in a
    /// right-to-left layout as Android's are (`seekFraction`). A tap moves the note to where it lands.
    private struct Waveform: View {
        /// The share of a bar's slot the bar fills, and the shortest it is drawn, of the waveform's height.
        private static let barShare = 0.55
        private static let shortest = 0.08
        /// How faint the bars still to play are.
        private static let unplayed = 0.3
        /// Where a bar sits in its slot, and on the waveform's height: centered.
        private static let center: CGFloat = 0.5

        let heights: [Double]
        let played: Double
        let tint: Color
        let seek: ((Double) -> Void)?
        @Environment(\.layoutDirection) private var direction

        var body: some View {
            Canvas { context, size in
                let slot = size.width / CGFloat(max(heights.count, 1))
                let barWidth = slot * Self.barShare
                let reached = Int((played * Double(heights.count)).rounded(.down))
                for (index, height) in heights.enumerated() {
                    let place = direction == .rightToLeft ? heights.count - 1 - index : index
                    let tall = size.height * CGFloat(max(height, Self.shortest))
                    let bar = CGRect(
                        x: CGFloat(place) * slot + (slot - barWidth) * Self.center,
                        y: (size.height - tall) * Self.center,
                        width: barWidth,
                        height: tall
                    )
                    let style = index < reached ? tint : tint.opacity(Self.unplayed)
                    context.fill(Path(roundedRect: bar, cornerRadius: barWidth * Self.center), with: .color(style))
                }
            }
            .contentShape(.rect)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { measured in
                width = measured
            }
            .gesture(
                SpatialTapGesture().onEnded { tap in
                    seek?(fraction(at: tap.location.x))
                },
                isEnabled: seek != nil
            )
        }

        /// The waveform's width, as last laid out.
        @State private var width: CGFloat = 1

        /// The share of the note at `offset` along the bars, read from the trailing edge in a right-to-left layout.
        private func fraction(at offset: CGFloat) -> Double {
            let along = Double(min(max(offset / max(width, 1), 0), 1))
            return direction == .rightToLeft ? 1 - along : along
        }
    }
#endif
