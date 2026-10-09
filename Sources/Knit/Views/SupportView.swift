#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// Support Knit, Android's Donate screen: the tip links on the US storefront (ADR 2026-10.zv5c), then Rate and Share.
    internal struct SupportView: View {
        /// The storefront's country, nil until StoreKit answers or when it has none.
        @State private var storefront: String?

        var body: some View {
            let showsTips = SupportLinks.showsTips(storefront: storefront)
            Form {
                Section {
                    Text(showsTips ? Copy.Support.tipsBlurb : Copy.Support.blurb)
                }
                if showsTips {
                    Section {
                        ForEach(SupportLinks.tips) { tip in
                            if let url = URL(string: tip.url) {
                                Link(destination: url) {
                                    RowLabel(tip.name, symbol: tip.symbol)
                                }
                                .accessibilityIdentifier(AccessibilityID.supportTip(tip.id))
                            }
                        }
                    } header: {
                        SectionNote(Copy.Support.tipsSection)
                    }
                }
                StoreSection()
            }
            .navigationTitle(Copy.Support.title)
            .task { storefront = await AppStorefront.countryCode() }
            .accessibilityIdentifier(AccessibilityID.supportScreen)
        }
    }

    /// Rate Knit, which opens the App Store's review sheet, and Share Knit, which sends Knit's App Store page.
    private struct StoreSection: View {
        var body: some View {
            Section {
                if let url = URL(string: SupportLinks.reviewURL) {
                    Link(destination: url) {
                        RowLabel(Copy.Support.rate, symbol: "star")
                    }
                    .accessibilityIdentifier(AccessibilityID.supportRate)
                }
                if let url = URL(string: SupportLinks.storeURL) {
                    ShareLink(item: url, message: Text(Copy.Support.shareMessage)) {
                        RowLabel(Copy.Support.share, symbol: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier(AccessibilityID.supportShare)
                }
            }
        }
    }
#endif
