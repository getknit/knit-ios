import KnitAppCore
import Testing

extension CopyCatalogTests {
    /// A link's preview card's strings (ADR 2026-11.hcvg), apart so the suite stays under the lint's length.
    static var linkPreviewStrings: [String] {
        [
            Copy.LinkPreviews.card(title: "A page", host: "example.com"),
            Copy.LinkPreviews.hidden,
            Copy.LinkPreviews.hiddenValue,
            Copy.LinkPreviews.show,
            Copy.LinkPreviews.loading,
            Copy.LinkPreviews.staged(title: "A page", host: "example.com"),
            Copy.LinkPreviews.remove,
            Copy.LinkPreviews.settingTitle,
            Copy.LinkPreviews.settingFooter,
        ]
    }

    /// VoiceOver names a card by the page's title, then the site, as Android's TalkBack does.
    @Test func aCardIsNamedByItsTitleThenItsSite() {
        #expect(Copy.LinkPreviews.card(title: "A page", host: "example.com") == "Link preview: A page, example.com")
        #expect(Copy.LinkPreviews.staged(title: "A page", host: "example.com").hasPrefix("Link preview: A page, example.com."))
    }

    /// The setting says what turning it on costs: the site sees the sender's address (ADR 2026-11.hcvg).
    @Test func theSettingSaysTheSiteSeesTheAddress() {
        #expect(Copy.LinkPreviews.settingFooter.contains("IP address"))
    }
}
