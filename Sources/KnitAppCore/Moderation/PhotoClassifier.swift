/// What scores a photo for the content filter: the bundled Core ML model in the app, a stand-in in tests and the demo.
public protocol PhotoClassifier: Sendable {
    /// The model's scores for the photo in `bytes`, one per class in ``ExplicitPhoto/classes`` order; `nil` when the
    /// model is missing or fails, or the bytes are no photo it reads. The filter then lets the photo through, as
    /// Android's does.
    func scores(of bytes: [UInt8]) async -> [Float]?
}

/// When a photo counts as explicit: Android's policy over its classifier's scores (`NsfwImageModerator.kt`), so both
/// platforms reach the same verdict from the same scores.
public enum ExplicitPhoto {
    /// The model's classes, in output order: GantMan's `nsfw_model` (`tools/models/nsfw/`).
    public static let classes = ["drawings", "hentai", "neutral", "porn", "sexy"]
    /// The classes summed into the score the threshold is held to.
    public static let unsafeClasses = ["hentai", "porn", "sexy"]
    /// Where ``unsafeClasses`` sit among the scores.
    private static let unsafeIndices = unsafeClasses.compactMap { classes.firstIndex(of: $0) }
    /// The summed score at which a photo counts as explicit. knit-next's docs say 0.7; its code says 0.9, and the code
    /// is what runs.
    public static let threshold: Float = 0.9

    /// The scores of the unsafe classes, summed; `0` for scores that are not one per class.
    public static func unsafeScore(_ scores: [Float]) -> Float {
        guard scores.count == classes.count else {
            return 0
        }
        return unsafeIndices.reduce(0) { $0 + scores[$1] }
    }

    /// Whether `scores` make a photo explicit. Scores that are not one per class come from some other model, and
    /// count as clean.
    public static func isExplicit(_ scores: [Float]) -> Bool {
        unsafeScore(scores) >= threshold
    }
}
