import KnitWire

/// What scores a message's words for the content filter: the bundled Core ML model in the app, a stand-in in tests and
/// the demo.
public protocol TextClassifier: Sendable {
    /// The model's scores for `text`, one per label in ``AbusiveText/labels`` order; `nil` when the model is missing or
    /// fails. The words then go through, as Android's do.
    func scores(of text: String) async -> [Float]?
}

/// When a message counts as abusive: Android's policy over its classifier's scores (`MlTextModerator.kt`), so both
/// platforms reach the same verdict from the same scores.
///
/// Only serious abuse is held against a message, each label against its own line. General rudeness (`toxicity`,
/// `insult`, `obscene`) and the identity columns, which name a topic rather than an attack, never are.
public enum AbusiveText {
    /// The model's labels, in output order: Detoxify's `unbiased-small` (`tools/models/toxicity/`).
    public static let labels = [
        "toxicity", "severe_toxicity", "obscene", "identity_attack", "insult", "threat", "sexual_explicit",
        "male", "female", "homosexual_gay_or_lesbian", "christian", "jewish", "muslim", "black", "white",
        "psychiatric_or_mental_illness",
    ]
    /// The lines Android draws: serious toxicity and an attack on who someone is at 0.85, sexually explicit words at 0.8,
    /// and a threat at 0.9.
    private static let seriousLine: Float = 0.85
    private static let explicitLine: Float = 0.8
    private static let threatLine: Float = 0.9
    /// The labels enforced, and the score at which each blocks (`MlTextModerator.DEFAULT_BLOCK_THRESHOLDS`).
    public static let lines: [(label: String, line: Float)] = [
        ("severe_toxicity", seriousLine), ("identity_attack", seriousLine), ("sexual_explicit", explicitLine), ("threat", threatLine),
    ]
    /// Where each enforced label sits among the scores, beside its line.
    private static let rules = lines.compactMap { rule in
        labels.firstIndex(of: rule.label).map { (index: $0, label: rule.label, line: rule.line) }
    }

    /// The enforced label that blocks `scores`, the highest-scoring one past its line, or `nil` when none is. Scores that
    /// are not one per label come from some other model, and block nothing.
    public static func blockingLabel(_ scores: [Float]) -> String? {
        guard scores.count == labels.count else {
            return nil
        }
        return rules.filter { scores[$0.index] >= $0.line }.max { scores[$0.index] < scores[$1.index] }?.label
    }

    /// Whether `scores` make a message abusive.
    public static func isAbusive(_ scores: [Float]) -> Bool {
        blockingLabel(scores) != nil
    }
}

/// The content filter for words (ADR 2026-10.e4kz): what a message we write is checked against before it is sent, and
/// what someone else's is screened with as it arrives (`ScopedTextModerator`).
///
/// The Nearby room runs the word list first and the model on what it lets through. A DM or a group runs the model alone:
/// profanity between people who chose each other is theirs, and only the room reaches strangers in range.
public final class TextScreening: Sendable {
    private let classifier: (any TextClassifier)?
    private let words: WordFilter

    /// The filter that runs `words` in the room and `classifier` everywhere; no classifier screens with the list alone.
    public init(classifier: (any TextClassifier)?, words: WordFilter) {
        self.classifier = classifier
        self.words = words
    }

    /// Whether `text` looks abusive, in the room when `inRoom`. Words the model could not read pass, as Android's do. A
    /// shared position is taken out first (`MeshManager.isTextFlagged`), and words that were only positions, or blank,
    /// pass too.
    public func isAbusive(_ text: String, inRoom: Bool) async -> Bool {
        let read = GeoTokens.strip(text)
        guard !TextLimits.isBlank(read) else {
            return false
        }
        if inRoom, words.flags(read) {
            return true
        }
        guard let classifier, let scores = await classifier.scores(of: read) else {
            return false
        }
        return AbusiveText.isAbusive(scores)
    }
}
