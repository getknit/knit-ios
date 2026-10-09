#if os(iOS)
    import StoreKit

    /// The App Store storefront, which decides whether Support Knit shows its tip links (ADR 2026-10.zv5c).
    internal enum AppStorefront {
        /// The storefront's ISO 3166-1 alpha-3 code, or nil when StoreKit has none, as in the Simulator.
        static func countryCode() async -> String? {
            await Storefront.current?.countryCode
        }
    }
#endif
