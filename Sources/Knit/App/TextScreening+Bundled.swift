#if os(iOS)
    import Foundation
    import KnitAppCore
    import KnitMesh

    extension TextScreening {
        /// The filter over `classifier` and the word lists bundled in the app, which reports a missing list to `log`.
        static func bundled(classifier: (any TextClassifier)?, log: any KnitLog) -> TextScreening {
            TextScreening(
                classifier: classifier,
                words: WordFilter(words: BundledList.terms("Profanity", log: log)),
                slurs: WordFilter(words: BundledList.terms("Slurs", log: log))
            )
        }
    }

    extension ShownNames {
        /// The name screen over the five word lists bundled in the app (knit-next ADR 2026-11.y4pc), which reports a
        /// missing list to `log`.
        static func bundled(log: any KnitLog) -> ShownNames {
            ShownNames(
                screen: NameScreen(
                    slurs: BundledList.terms("Slurs", log: log),
                    profanity: BundledList.terms("Profanity", log: log),
                    embeddable: BundledList.terms("NameEmbeddable", log: log),
                    exclusions: BundledList.terms("NameExclusions", log: log),
                    allowedNames: BundledList.terms("NameAllowed", log: log)
                )
            )
        }
    }

    /// A word list bundled as `<name>.txt`, each Android's file: `Profanity`, the Nearby room's (knit-next's
    /// `profanity_en.txt`), `Slurs`, every conversation's (its `slurs_en.txt`, knit-next ADR 2026-10.d62w), and the name
    /// screen's `NameEmbeddable`, `NameExclusions` and `NameAllowed` (its `name_*_en.txt`, ADR 2026-11.y4pc there).
    private enum BundledList {
        /// The list's terms. Without the file the filter screens without that list, and says so, as Android's does.
        static func terms(_ name: String, log: any KnitLog) -> [String] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
                let text = try? String(contentsOf: url, encoding: .utf8)
            else {
                log.log(.warning, "text filter: \(name).txt is not in the app, so the filter screens without it")
                return []
            }
            return WordFilter.terms(in: text)
        }
    }
#endif
