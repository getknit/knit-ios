#if os(iOS)
    import Foundation
    import KnitAppCore
    import KnitMesh

    extension TextScreening {
        /// The filter over `classifier` and the word lists bundled in the app, which reports a missing list to `log`.
        static func bundled(classifier: (any TextClassifier)?, log: any KnitLog) -> TextScreening {
            TextScreening(classifier: classifier, words: wordList("Profanity", log: log), slurs: wordList("Slurs", log: log))
        }

        /// A word list bundled as `<name>.txt`: `Profanity`, the Nearby room's (knit-next's `profanity_en.txt`), or
        /// `Slurs`, every conversation's (its `slurs_en.txt`, knit-next ADR 2026-10.d62w). Without it the filter screens
        /// without that list, and says so.
        private static func wordList(_ name: String, log: any KnitLog) -> WordFilter {
            guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
                let text = try? String(contentsOf: url, encoding: .utf8)
            else {
                log.log(.warning, "text filter: \(name).txt is not in the app, so the filter screens without it")
                return WordFilter(words: [])
            }
            return WordFilter(list: text)
        }
    }
#endif
