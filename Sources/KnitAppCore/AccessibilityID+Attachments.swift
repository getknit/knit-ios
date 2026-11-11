// A message's attachment, apart from `AccessibilityID.swift` only to keep that file under the lint's length.
extension AccessibilityID {
    /// A photo still on its way.
    public static let chatAttachmentWaiting = "chat_attachment_wait"
    /// A photo streaming in, under its ring and how much of it is in (`chat_attachment_progress`).
    public static let chatAttachmentArriving = "chat_attachment_progress"
    /// A photo that is not fetched until something changes: a message request's, or a stranger's past the room's bound
    /// (knit-ios #21). Android has no tag here.
    public static let chatAttachmentHeldBack = "chat_attachment_held_back"
    /// A photo whose bytes are here and do not open.
    public static let chatAttachmentUnavailable = "chat_attachment_unavailable"
    /// A voice message or a file, which this build names and cannot open. Android has no tag here.
    public static let chatAttachmentTile = "chat_attachment_tile"
    /// A photo the content filter hides until it is tapped (ADR 2026-10.rpmq). Android has no tag here.
    public static let chatAttachmentHidden = "chat_attachment_hidden"
    /// A link's preview card in a bubble (`chat_link_card`, ADR 2026-11.hcvg).
    public static let chatLinkCard = "chat_link_card"
    /// A link's preview card the content filter hides until it is tapped (`chat_link_card_hidden`).
    public static let chatLinkCardHidden = "chat_link_card_hidden"
    /// The card the composer holds for Send (`chat_link_staged`).
    public static let chatLinkStaged = "chat_link_staged"
    /// The composer's cross on the card it holds. Android has no tag here.
    public static let chatRemoveLinkCard = "chat_link_staged_remove"
    /// The composer's line while it fetches the draft's card. Android has no tag here.
    public static let chatLinkLoading = "chat_link_loading"
    /// Settings' link previews switch (`settings_link_previews`), in a build with link previews.
    public static let settingsLinkPreviews = "settings_link_previews"
    /// The composer's mic (`chat_voice_record`).
    public static let chatVoiceRecord = "chat_voice_record"
    /// The bar in the field's place while a note records (`chat_voice_recording`).
    public static let chatVoiceRecording = "chat_voice_recording"
    /// The locked recording's cancel (`chat_voice_cancel`).
    public static let chatVoiceCancel = "chat_voice_cancel"
    /// The locked recording's stop, which keeps it (`chat_voice_stop`).
    public static let chatVoiceStop = "chat_voice_stop"
    /// A voice note's play button, in a bubble or in the composer (`chat_voice_play`).
    public static let chatVoicePlay = "chat_voice_play"
    /// The voice note the composer holds (`chat_voice_staged`).
    public static let chatVoiceStaged = "chat_voice_staged"
    /// The button that takes the held voice note out. Android has no tag here.
    public static let chatVoiceRemove = "chat_voice_remove"

    /// A message carrying a voice note, as VoiceOver and the UI tests reach it. Android has no tag here.
    public static func chatVoice(_ messageId: String) -> String {
        "chat_voice_message_\(messageId)"
    }
}
