import Testing

@testable import KnitAppCore

/// Support Knit (ADR 2026-10.zv5c): Android's tip links, shown on the US storefront alone, and Knit's App Store page.
@Suite struct SupportTests {
    @Test func theTipLinksShowOnTheUSStorefrontAlone() {
        #expect(SupportLinks.showsTips(storefront: "USA"))
        #expect(!SupportLinks.showsTips(storefront: "CAN"))
        #expect(!SupportLinks.showsTips(storefront: "DEU"))
        #expect(!SupportLinks.showsTips(storefront: "US"), "StoreKit's code has three letters")
        #expect(!SupportLinks.showsTips(storefront: nil), "no storefront, as in the Simulator, shows none")
    }

    /// Android's platforms, in its order (`DONATION_PLATFORMS` in `ui/donate/DonateScreen.kt`).
    @Test func theTipsAreAndroidsInItsOrder() {
        #expect(
            SupportLinks.tips.map(\.url) == [
                "https://ko-fi.com/knit", "https://liberapay.com/zaventh/", "https://github.com/sponsors/getknit",
            ])
        #expect(SupportLinks.tips.map(\.name) == ["Ko-fi", "Liberapay", "GitHub Sponsors"])
        #expect(Set(SupportLinks.tips.map(\.id)).count == SupportLinks.tips.count)
        #expect(AccessibilityID.supportTip("kofi") == "support_tip_kofi")
        #expect(AccessibilityID.supportScreen == "screen_donate", "Android's tag")
    }

    @Test func rateAndShareGoToKnitsAppStorePage() {
        #expect(SupportLinks.storeURL == "https://apps.apple.com/app/id6820348510")
        #expect(SupportLinks.reviewURL == "https://apps.apple.com/app/id6820348510?action=write-review")
    }
}

extension CopyCatalogTests {
    /// Support Knit's strings (ADR 2026-10.zv5c), apart so the suite stays under the lint's length.
    static var supportStrings: [String] {
        [
            Copy.Support.title,
            Copy.Support.tipsBlurb,
            Copy.Support.blurb,
            Copy.Support.tipsSection,
            Copy.Support.rate,
            Copy.Support.share,
            Copy.Support.shareMessage,
        ]
    }
}
