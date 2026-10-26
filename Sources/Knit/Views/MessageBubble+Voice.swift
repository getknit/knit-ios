#if os(iOS)
    import KnitAppCore
    import SwiftUI

    // A message's voice note, apart from `MessageBubble.swift` only to keep that file under the lint's length.
    extension MessageBubble {
        /// What the UI tests reach the message by: a photo's, a voice note's, or any message's.
        var identifier: String {
            if message.attachment?.kind == .photo {
                return AccessibilityID.chatPhoto(message.id)
            }
            if message.attachment?.voiceShowing == .player {
                return AccessibilityID.chatVoice(message.id)
            }
            return AccessibilityID.chatMessage(message.id)
        }

        /// VoiceOver's Play or Pause on a message whose voice note is here to play, as its photo opens from the message's
        /// one element.
        @ViewBuilder var voiceActions: some View {
            if let note = message.attachment, note.voiceShowing == .player, note.isHeld, let voiceSession {
                let playing = voiceSession.voiceNotes?.playback.position(of: note.hash)?.playing == true
                Button(playing ? Copy.Voice.pause : Copy.Voice.play) {
                    Task { await voiceSession.toggleVoice(note) }
                }
            }
        }
    }
#endif
