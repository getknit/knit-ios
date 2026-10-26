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
