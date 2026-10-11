/// The demo's text filter: every message scores as a threat under `-demoSensitive`, and so do the words a scene names
/// for it to flag (``DemoScene/flaggedWords``); everything else scores as harmless, whatever it says. The demo's words are
/// friendly, and nothing in the repository is abusive: a scene that shows the filter at work names the lines it hides.
public struct DemoTextClassifier: TextClassifier {
    /// Whether every message looks abusive.
    public let flagsEverything: Bool
    /// The words that look abusive when not everything does.
    public let flagging: Set<String>

    /// A classifier that finds every message abusive when `flagsEverything`, and otherwise only `flagging`.
    public init(flagsEverything: Bool, flagging: Set<String> = []) {
        self.flagsEverything = flagsEverything
        self.flagging = flagging
    }

    public func scores(of text: String) -> [Float]? {
        let flagged = flagsEverything || flagging.contains(text)
        return AbusiveText.labels.map { $0 == "threat" && flagged ? 1 : 0 }
    }
}
