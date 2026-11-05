import KnitAppCore
import Testing

extension CopyCatalogTests {
    /// Sharing's strings, apart so the suite stays under the lint's length.
    static var shareStrings: [String] {
        [
            Copy.Share.held(.words),
            Copy.Share.held(.explicitPhoto),
            Copy.Share.held(.unreadablePhoto),
            Copy.Share.held(.photoTooLarge),
            Copy.Share.held(.closed),
        ]
    }

    /// The sample chats' strings, apart for the same reason.
    static var sampleStrings: [String] {
        [Copy.Sample.open, Copy.Sample.banner, Copy.Sample.leave, Copy.Sample.leaveLabel, Copy.Sample.settingsFooter]
    }
}
