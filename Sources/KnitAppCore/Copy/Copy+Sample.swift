import Foundation

extension Copy {
    /// The sample chats (ADR 2026-11.pydf): made-up people anyone can open, for someone with nobody nearby yet. The banner
    /// stays above them, because someone in a real outage must never take a sample for the real thing.
    public enum Sample {
        /// The way in, on the first-run card and in Settings.
        public static var open: String {
            NSLocalizedString(
                "sample.open",
                bundle: .main,
                value: "Try sample chats",
                comment: "Sample chats: the button that opens them, on the first-run card and in Settings"
            )
        }

        /// The banner above the sample chats.
        public static var banner: String {
            NSLocalizedString(
                "sample.banner",
                bundle: .main,
                value: "Sample chats. The people are made up, and nothing you send reaches anyone.",
                comment: "Sample chats: the banner that stays above them, so nobody takes them for real ones"
            )
        }

        /// The banner's button, back to the real app.
        public static var leave: String {
            NSLocalizedString(
                "sample.leave", bundle: .main, value: "Leave", comment: "Sample chats: the banner's button, back to the real app")
        }

        /// The banner's button, as VoiceOver reads it.
        public static var leaveLabel: String {
            NSLocalizedString(
                "sample.leave.label",
                bundle: .main,
                value: "Leave sample chats",
                comment: "Sample chats: VoiceOver's name for the banner's Leave button"
            )
        }

        /// What Settings says under the way in.
        public static var settingsFooter: String {
            NSLocalizedString(
                "sample.settings.footer",
                bundle: .main,
                value: "Made-up chats show how Knit looks with people around. Your own chats stay as they are.",
                comment: "Settings: under Try sample chats, what they are and that the user's own chats aren't touched"
            )
        }
    }
}
