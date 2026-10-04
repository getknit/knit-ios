#if os(iOS)
    import Foundation
    import KnitAppCore

    /// ``AppPreferences`` in UserDefaults, which goes with the app when it is deleted: a reinstall onboards again.
    internal final class DefaultsPreferences: AppPreferences {
        private static let onboardedKey = "hasOnboarded"
        private static let filtersKey = "filtersContent"

        // UserDefaults is thread-safe, as its documentation says; its declaration just isn't Sendable.
        nonisolated(unsafe) private let defaults = UserDefaults.standard

        var hasOnboarded: Bool {
            get { defaults.bool(forKey: Self.onboardedKey) }
            set { defaults.set(newValue, forKey: Self.onboardedKey) }
        }

        /// On until someone turns it off, as Android's `contentFilteringEnabled` is: a key never written reads as on.
        var filtersContent: Bool {
            get { defaults.object(forKey: Self.filtersKey) as? Bool ?? true }
            set { defaults.set(newValue, forKey: Self.filtersKey) }
        }
    }
#endif
