/// Where Support Knit's rows go: the tip platforms Android's `DonateScreen` lists, and Knit's App Store page.
public enum SupportLinks {
    /// One tip platform: its key, its name, its SF Symbol and where it goes.
    public struct Tip: Sendable, Equatable, Identifiable {
        /// A key that names it in identifiers, which never changes with the words.
        public let id: String
        /// The platform's name.
        public let name: String
        /// The SF Symbol before it.
        public let symbol: String
        /// The maintainer's page there.
        public let url: String
    }

    /// The tip platforms, in Android's order (`DONATION_PLATFORMS` in knit-next's `ui/donate/DonateScreen.kt`).
    public static let tips: [Tip] = [
        Tip(id: "kofi", name: Copy.Support.kofi, symbol: "cup.and.saucer", url: "https://ko-fi.com/knit"),
        Tip(id: "liberapay", name: Copy.Support.liberapay, symbol: "hands.and.sparkles", url: "https://liberapay.com/zaventh/"),
        Tip(
            id: "github_sponsors",
            name: Copy.Support.githubSponsors,
            symbol: "chevron.left.forwardslash.chevron.right",
            url: "https://github.com/sponsors/getknit"
        ),
    ]

    /// Knit's Apple id in App Store Connect, assigned with the app record.
    public static let appStoreID = "6820348510"

    /// Knit's App Store page, which Share sends.
    public static var storeURL: String {
        "https://apps.apple.com/app/id\(appStoreID)"
    }

    /// Knit's App Store page with the review sheet open, which Rate opens.
    public static var reviewURL: String {
        "\(storeURL)?action=write-review"
    }

    /// Whether the tip links show in `storefront`, an ISO 3166-1 alpha-3 code or nil when StoreKit has none. App
    /// Review allows a link out to pay the developer only on the US storefront (guideline 3.1.1(a)), so an unknown
    /// storefront shows none (ADR 2026-10.zv5c).
    public static func showsTips(storefront: String?) -> Bool {
        storefront == "USA"
    }
}
