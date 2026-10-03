import Foundation

extension Copy {
    /// What a message carries beside its words: a photo in a thread and in the composer, and a voice message or a file
    /// this build names. A list's and a notification's lines lead with an emoji, as Android's do.
    public enum Attachments {
        /// The line for a message that is a photo and no words.
        public static var photoPreview: String {
            NSLocalizedString(
                "attachments.preview.photo",
                bundle: .main,
                value: "📷 Photo",
                comment: "Chat list and notifications: a message that is a photo and no words"
            )
        }

        /// The line for a message that is a GIF and no words.
        public static var gifPreview: String {
            NSLocalizedString(
                "attachments.preview.gif",
                bundle: .main,
                value: "🎞️ GIF",
                comment: "Chat list and notifications: a message that is a GIF and no words"
            )
        }

        /// The line for a voice message.
        public static var voicePreview: String {
            NSLocalizedString(
                "attachments.preview.voice",
                bundle: .main,
                value: "🎤 Voice message",
                comment: "Chat list and notifications: a voice message sent from Android"
            )
        }

        /// The line for a file, by its name.
        public static func filePreview(_ name: String) -> String {
            format(
                NSLocalizedString(
                    "attachments.preview.file",
                    bundle: .main,
                    value: "📎 %@",
                    comment: "Chat list and notifications: a file sent from Android; %@ is its name"
                ),
                name
            )
        }

        /// The line for a link's preview card with no words, which no build sends.
        public static var linkPreview: String {
            NSLocalizedString(
                "attachments.preview.link",
                bundle: .main,
                value: "🔗 Link",
                comment: "Chat list and notifications: a link's preview card with no words"
            )
        }

        /// A photo in a thread, for VoiceOver.
        public static var photo: String {
            NSLocalizedString(
                "attachments.photo", bundle: .main, value: "Photo", comment: "Chat: VoiceOver's name for a photo in a message")
        }

        /// A voice message's name in a thread.
        public static var voiceMessage: String {
            NSLocalizedString(
                "attachments.voice",
                bundle: .main,
                value: "Voice message",
                comment: "Chat: a voice message sent from Android, in place of the player this build lacks"
            )
        }

        /// A file's name in a thread when its sender gave none.
        public static var file: String {
            NSLocalizedString("attachments.file", bundle: .main, value: "File", comment: "Chat: a file sent from Android with no name")
        }

        /// What a photo still on its way says (`chat_loading_photo`).
        public static var photoWaiting: String {
            NSLocalizedString(
                "attachments.photo.waiting",
                bundle: .main,
                value: "Photo appears once a phone that has it is in range",
                comment: "Chat: a photo whose bytes have not arrived yet"
            )
        }

        /// A photo whose bytes are here and do not open.
        public static var photoUnreadable: String {
            NSLocalizedString(
                "attachments.photo.unreadable",
                bundle: .main,
                value: "Can't show this photo",
                comment: "Chat: a photo whose bytes arrived and could not be opened"
            )
        }

        /// What a voice message says under its name.
        public static var voiceUnsupported: String {
            NSLocalizedString(
                "attachments.voice.unsupported",
                bundle: .main,
                value: "Knit for iPhone can't play voice messages yet",
                comment: "Chat: under a voice message, which Knit for iPhone cannot play"
            )
        }

        /// What a file says under its name.
        public static var fileUnsupported: String {
            NSLocalizedString(
                "attachments.file.unsupported",
                bundle: .main,
                value: "Knit for iPhone can't open files yet",
                comment: "Chat: under a file, which Knit for iPhone cannot open"
            )
        }

        /// What tapping a photo does, for VoiceOver.
        public static var viewPhoto: String {
            NSLocalizedString("attachments.photo.view", bundle: .main, value: "View photo", comment: "Chat: opens a photo full screen")
        }

        /// The composer's button that picks a photo.
        public static var addPhoto: String {
            NSLocalizedString("attachments.add-photo", bundle: .main, value: "Add photo", comment: "Chat: the composer's photo button")
        }

        /// The picked photo in the composer, for VoiceOver.
        public static var stagedPhoto: String {
            NSLocalizedString(
                "attachments.staged",
                bundle: .main,
                value: "Photo to send",
                comment: "Chat: VoiceOver's name for the photo the composer holds"
            )
        }

        /// The button that takes the photo out of the composer.
        public static var removePhoto: String {
            NSLocalizedString(
                "attachments.remove-photo",
                bundle: .main,
                value: "Remove photo",
                comment: "Chat: takes the picked photo out of the composer"
            )
        }

        /// The viewer's button that saves the photo to the library.
        public static var save: String {
            NSLocalizedString("attachments.save", bundle: .main, value: "Save to Photos", comment: "Photo viewer: saves the photo")
        }

        /// The photo was saved.
        public static var saved: String {
            NSLocalizedString("attachments.saved", bundle: .main, value: "Saved to Photos", comment: "Photo viewer: the photo was saved")
        }

        /// The photo could not be saved, with Knit allowed to add to Photos.
        public static var saveFailed: String {
            NSLocalizedString(
                "attachments.save-failed",
                bundle: .main,
                value: "Couldn't save this photo.",
                comment: "Photo viewer: the photo could not be saved, though Knit may add to Photos"
            )
        }

        /// The photo could not be saved, since Knit may not add to Photos.
        public static var saveDenied: String {
            NSLocalizedString(
                "attachments.save-denied",
                bundle: .main,
                value: "Knit isn't allowed to add to Photos. You can change that in Settings.",
                comment: "Photo viewer: the photo could not be saved because adding to Photos is off for Knit"
            )
        }
    }
}
