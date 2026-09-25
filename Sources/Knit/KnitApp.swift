#if canImport(SwiftUI)
    import KnitAppCore
    import SwiftUI

    // periphery:ignore - the @main entry point; xtool's wrapper executable is its only caller
    /// The app entry point xtool packs from the `Knit` library product.
    @main
    internal struct KnitApp: App {
        var body: some Scene {
            WindowGroup {
                Text(verbatim: KnitAppCore.productName)
            }
        }
    }
#endif
