/// The composer's voice notes (knit-next ADR 034): where its mic shows. The recorder itself is ``ChatModel/voice``.
extension ChatModel {
    /// Whether the composer shows its mic (`ChatScreen.kt:4599-4601`): in a build with voice notes, in a DM or a group,
    /// never the room (knit-next ADR 034 §4), while there is nothing to send. Once a press records, the mic stays for as
    /// long as the finger holds it, since the gesture ends with its view, and gives way to Stop once the recording locks.
    public var offersVoice: Bool {
        guard let voice, !state.isRoom else {
            return false
        }
        return voice.isRecording ? !voice.isLocked : !canSend && !isSending
    }

    /// A press on the mic: what plays stops, so the recording hears the room and not the note, and the recorder starts,
    /// locked for VoiceOver's activation (``VoiceRecorder/press(locked:)``).
    public func startRecording(locked: Bool = false) {
        session.voiceNotes?.playback.stop()
        voice?.press(locked: locked)
    }

    /// Knit left the screen: a recording is kept for the composer, and a note playing pauses where it is.
    public func leave() {
        voice?.leave()
        session.voiceNotes?.playback.pause()
    }

    /// `attachment` as this thread shows a voice note: its player in a DM or a group in a build with voice notes, and the
    /// room's tile in Nearby. A build without them keeps the tile that says it can't play one.
    func showVoice(kind: ThreadKind) -> (ChatAttachment) -> ChatAttachment {
        let plays = voice != nil
        return { attachment in
            var shown = attachment
            if shown.playsAsVoice, plays {
                shown.voiceShowing = kind == .room ? .notInNearby : .player
            }
            return shown
        }
    }

    /// The composer's Remove on the held note: it leaves the composer, and stops if it plays.
    public func removeVoice() {
        if let note = voice?.staged, session.voiceNotes?.playback.nowPlaying?.hash == note.hash {
            session.voiceNotes?.playback.stop()
        }
        voice?.removeStaged()
    }
}
