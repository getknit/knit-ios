#if os(iOS)
    import Foundation
    import KnitAppCore

    /// ``AppPreferences`` in UserDefaults, which goes with the app when it is deleted: a reinstall onboards again.
    internal final class DefaultsPreferences: AppPreferences {
        private static let onboardedKey = "hasOnboarded"
        private static let filtersKey = "filtersContent"
        private static let termsKey = "acceptedTerms"
        private static let linkPreviewsKey = "linkPreviews"

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

        /// 0, a key never written, until the user agrees to the terms (ADR 2026-10.cgm3).
        var acceptedTerms: Int {
            get { defaults.integer(forKey: Self.termsKey) }
            set { defaults.set(newValue, forKey: Self.termsKey) }
        }

        /// Off, a key never written, until someone turns it on, as Android's `linkPreviewsEnabled` is (ADR 2026-11.hcvg).
        var linkPreviews: Bool {
            get { defaults.bool(forKey: Self.linkPreviewsKey) }
            set { defaults.set(newValue, forKey: Self.linkPreviewsKey) }
        }

        /// Internet relays' list as the bytes kept, in a debug build alone (ADR 2026-11.adrq, P6): a release build reads and
        /// keeps none. Bytes that do not read as a list are left as they are (``StoredRelayBook/unreadable``), never written
        /// over.
        var relayBookData: Data? {
            get {
                #if DEBUG
                    defaults.data(forKey: Self.relayBookKey)
                #else
                    nil
                #endif
            }
            set {
                #if DEBUG
                    defaults.set(newValue, forKey: Self.relayBookKey)
                #endif
            }
        }

        #if DEBUG
            // `scripts/check.sh release` fails when a release build holds this key: it would mean the relay list ships.
            private static let relayBookKey = "debug.spool.relays"
        #endif
    }
#endif
