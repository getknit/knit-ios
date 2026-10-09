import Foundation

extension Copy {
    /// Support Knit: Android's Donate screen, with its tip links on the US storefront alone (ADR 2026-10.zv5c).
    public enum Support {
        /// The screen's title, and Settings' row.
        public static var title: String {
            NSLocalizedString(
                "support.title", bundle: .main, value: "Support Knit", comment: "Support: the screen's title and Settings' row")
        }

        /// What tips pay for, over the tip links.
        public static var tipsBlurb: String {
            NSLocalizedString(
                "support.blurb.tips",
                bundle: .main,
                value: """
                    Knit is free and paid for by tips. It shows no ads and doesn't track you. If it's useful to you, a small tip keeps \
                    the work going.
                    """,
                comment: "Support: over the tip links, what tips pay for"
            )
        }

        /// What helps, where the storefront shows no tip links.
        public static var blurb: String {
            NSLocalizedString(
                "support.blurb",
                bundle: .main,
                value: """
                    Knit is free, shows no ads and doesn't track you. If it's useful to you, a rating or a word to a friend helps more \
                    people find it.
                    """,
                comment: "Support: over Rate and Share, where no tip links show"
            )
        }

        /// The header over the tip links.
        public static var tipsSection: String {
            NSLocalizedString("support.tips", bundle: .main, value: "Leave a tip", comment: "Support: the header over the tip links")
        }

        /// The Ko-fi link's name, which is never translated.
        public static let kofi = "Ko-fi"
        /// The Liberapay link's name, which is never translated.
        public static let liberapay = "Liberapay"
        /// The GitHub Sponsors link's name, which is never translated.
        public static let githubSponsors = "GitHub Sponsors"

        /// The row that opens Knit's review page on the App Store.
        public static var rate: String {
            NSLocalizedString("support.rate", bundle: .main, value: "Rate Knit", comment: "Support: opens the App Store to rate Knit")
        }

        /// The row that opens the share sheet.
        public static var share: String {
            NSLocalizedString("support.share", bundle: .main, value: "Share Knit", comment: "Support: shares a link to Knit")
        }

        /// What the share sheet sends beside the App Store link.
        public static var shareMessage: String {
            NSLocalizedString(
                "support.share.message",
                bundle: .main,
                value: "Knit is a free messenger that works without the internet or an account: phones talk to each other directly.",
                comment: "Support: the message shared beside Knit's App Store link"
            )
        }
    }
}
