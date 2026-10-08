import KnitAppCore

extension CopyCatalogTests {
    /// What the info sheets say, a point at a time, and the short lines they took the place of, apart so the suite stays
    /// under the lint's length.
    static var infoStrings: [String] {
        [
            Copy.Status.boundaryBackground,
            Copy.Status.boundaryLater,
            Copy.Settings.meshInfo,
            Copy.Settings.stopDetail,
            Copy.Chat.encryptionSealed,
            Copy.Chat.encryptionReactions,
            Copy.Chat.encryptionSecrecy,
            Copy.Groups.encryptionRoster,
            Copy.Groups.encryptionSecrecy,
            Copy.Moderation.filterInfo,
            Copy.Moderation.filterOnDevice,
            Copy.Moderation.filterProfilePhoto,
            Copy.Moderation.filterMistakes,
            Copy.ChatList.justNow,
        ]
    }
}
