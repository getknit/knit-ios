import Foundation

extension Copy {
    /// The photo cropper and the photo viewer.
    public enum Photo {
        /// The cropper's hint, over the photo.
        public static var cropHint: String {
            NSLocalizedString(
                "photo.crop.hint",
                bundle: .main,
                value: "Drag and pinch to adjust",
                comment: "Photo cropper: how to place the photo in the circle"
            )
        }

        /// The cropper's button that keeps the crop. The profile's Save publishes it, so this is not Save.
        public static var cropChoose: String {
            NSLocalizedString(
                "photo.crop.choose",
                bundle: .main,
                value: "Choose",
                comment: "Photo cropper: keeps the photo as placed, for the profile's Save to publish"
            )
        }

        /// The photo under the circle, for VoiceOver, which zooms it.
        public static var zoom: String {
            NSLocalizedString("photo.crop.zoom", bundle: .main, value: "Zoom", comment: "Photo cropper: VoiceOver's name for the zoom")
        }

        /// A picked photo that could not be read or cropped.
        public static var unreadable: String {
            NSLocalizedString(
                "photo.unreadable",
                bundle: .main,
                value: "Knit couldn't open that photo. Try another one.",
                comment: "Own profile: the picked image could not be read"
            )
        }

        /// A picked photo too large to send: past the most pixels Knit opens, or still over 8 MB once shrunk.
        public static var tooLarge: String {
            NSLocalizedString(
                "photo.too-large",
                bundle: .main,
                value: "That photo is too large to send. Try a smaller one.",
                comment: "Chat: the picked image is too large to send, even made smaller"
            )
        }

        /// The photo the viewer shows, for VoiceOver.
        public static var profilePhoto: String {
            NSLocalizedString(
                "photo.viewer.profile-photo",
                bundle: .main,
                value: "Profile photo",
                comment: "Photo viewer: VoiceOver's name for the photo"
            )
        }
    }
}
