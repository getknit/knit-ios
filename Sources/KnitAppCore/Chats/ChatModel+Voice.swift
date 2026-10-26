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
}
