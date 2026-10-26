import Foundation

extension Copy {
    /// A voice message: its bubble, the composer's mic and recording bar, and what a press that kept nothing says
    /// (knit-next's "Voice notes" strings, ADR 034).
    public enum Voice {
        /// The play button on a voice message (`chat_voice_play`).
        public static var play: String {
            NSLocalizedString("voice.play", bundle: .main, value: "Play voice message", comment: "Chat: the play button on a voice message")
        }

        /// The play button while it plays (`chat_voice_pause`).
        public static var pause: String {
            NSLocalizedString(
                "voice.pause", bundle: .main, value: "Pause voice message", comment: "Chat: the pause button on a playing voice message")
        }

        /// A voice message for VoiceOver, with its length as the bubble shows it (`chat_voice_desc`).
        public static func described(length: String) -> String {
            Copy.format(
                NSLocalizedString(
                    "voice.described",
                    bundle: .main,
                    value: "Voice message, %@",
                    comment: "Chat: VoiceOver's name for a voice message; %@ is its length, such as 0:42"
                ),
                length
            )
        }

        /// A voice message for VoiceOver while it plays or rests part played: its length, and how far it has got, which its
        /// clock shows.
        public static func playing(length: String, at place: String) -> String {
            Copy.format(
                NSLocalizedString(
                    "voice.playing",
                    bundle: .main,
                    value: "Voice message, %1$@, at %2$@",
                    comment: "Chat: VoiceOver's name for a voice message part played; %1$@ is its length, %2$@ how far it has played"
                ),
                length,
                place
            )
        }

        /// What a voice message still on its way says (`chat_voice_loading`), in the iPhone's words for a photo's.
        public static var waiting: String {
            NSLocalizedString(
                "voice.waiting",
                bundle: .main,
                value: "Voice message appears once a phone that has it is in range",
                comment: "Chat: a voice message whose sound has not arrived yet"
            )
        }

        /// A voice message whose sound is here and doesn't play.
        public static var unplayable: String {
            NSLocalizedString(
                "voice.unplayable",
                bundle: .main,
                value: "Can't play this voice message",
                comment: "Chat: a voice message whose sound arrived and could not be played"
            )
        }

        /// Under a voice message posted in the Nearby room, which this build doesn't play: no one screens its sound, and
        /// the room is open to everyone in range.
        public static var notInNearby: String {
            NSLocalizedString(
                "voice.not-in-nearby",
                bundle: .main,
                value: "Voice messages play in direct messages and groups, not in Nearby",
                comment: "Chat: under a voice message someone posted in the Nearby room, which Knit doesn't play there"
            )
        }

        /// The mic's VoiceOver action, which starts a recording that runs until Stop (`chat_voice_record_start`).
        public static var recordStart: String {
            NSLocalizedString(
                "voice.record-start",
                bundle: .main,
                value: "Record a voice message",
                comment: "Chat: VoiceOver's action on the microphone button, which records until Stop"
            )
        }

        /// The button that ends a locked recording and keeps it (`chat_voice_record_stop`).
        public static var stop: String {
            NSLocalizedString(
                "voice.stop", bundle: .main, value: "Stop recording", comment: "Chat: the button that ends a recording and keeps it")
        }

        /// The recording bar's dot, for VoiceOver (`chat_voice_recording`).
        public static var recording: String {
            NSLocalizedString(
                "voice.recording", bundle: .main, value: "Recording", comment: "Chat: the recording bar's red dot, for VoiceOver")
        }

        /// What the recording bar says while the finger holds it (`chat_voice_slide_to_cancel`).
        public static var slideToCancel: String {
            NSLocalizedString(
                "voice.slide-to-cancel",
                bundle: .main,
                value: "Slide to cancel",
                comment: "Chat: the recording bar while the microphone button is held; sliding away cancels"
            )
        }

        /// The button that throws a locked recording away (`chat_voice_cancel`).
        public static var cancel: String {
            NSLocalizedString(
                "voice.cancel", bundle: .main, value: "Cancel recording", comment: "Chat: the button that throws a recording away")
        }

        /// The button on the composer's held voice message that takes it out (`chat_voice_remove`).
        public static var remove: String {
            NSLocalizedString(
                "voice.remove",
                bundle: .main,
                value: "Remove voice message",
                comment: "Chat: the button that takes the recorded voice message out of the composer"
            )
        }

        /// What a press too short to keep says (`chat_voice_too_short`).
        public static var tooShort: String {
            NSLocalizedString(
                "voice.too-short",
                bundle: .main,
                value: "Hold the mic button to record",
                comment: "Chat: after a tap on the microphone button too short to record anything"
            )
        }

        /// What a recording that failed says (`chat_voice_record_failed`).
        public static var unrecorded: String {
            NSLocalizedString(
                "voice.unrecorded",
                bundle: .main,
                value: "Couldn't record that voice message. Try again.",
                comment: "Chat: the microphone was busy, or the recording didn't come out"
            )
        }

        /// The alert's title when the microphone is refused (`chat_voice_mic_denied_title`).
        public static var microphoneOffTitle: String {
            NSLocalizedString(
                "voice.microphone-off.title",
                bundle: .main,
                value: "Microphone access is off",
                comment: "Chat: the alert's title when Knit may not use the microphone"
            )
        }

        /// The alert's words when the microphone is refused (`chat_voice_mic_denied_settings`), over Open Settings.
        public static var microphoneOffMessage: String {
            NSLocalizedString(
                "voice.microphone-off.message",
                bundle: .main,
                value: "Turn on the microphone for Knit in Settings to record voice messages. Knit uses it only while you're recording.",
                comment: "Chat: the alert when Knit may not use the microphone, over a button that opens Settings"
            )
        }
    }
}
