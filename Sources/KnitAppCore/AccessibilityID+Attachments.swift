// A message's attachment, apart from `AccessibilityID.swift` only to keep that file under the lint's length.
extension AccessibilityID {
    /// A photo still on its way.
    public static let chatAttachmentWaiting = "chat_attachment_wait"
    /// A photo streaming in, under its ring and how much of it is in (`chat_attachment_progress`).
    public static let chatAttachmentArriving = "chat_attachment_progress"
    /// A photo whose bytes are here and do not open.
    public static let chatAttachmentUnavailable = "chat_attachment_unavailable"
    /// A voice message or a file, which this build names and cannot open. Android has no tag here.
    public static let chatAttachmentTile = "chat_attachment_tile"
    /// A photo the content filter hides until it is tapped (ADR 2026-10.rpmq). Android has no tag here.
    public static let chatAttachmentHidden = "chat_attachment_hidden"
}
