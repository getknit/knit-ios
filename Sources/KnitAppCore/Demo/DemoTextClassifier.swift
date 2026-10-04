/// The demo's text filter: every message scores as a threat under `-demoSensitive`, and as harmless otherwise, whatever
/// it says. The demo's words are friendly, and nothing in the repository is abusive.
public struct DemoTextClassifier: TextClassifier {
    /// Whether every message looks abusive.
    public let flagsEverything: Bool

    /// A classifier that finds every message abusive when `flagsEverything`, and none otherwise.
    public init(flagsEverything: Bool) {
        self.flagsEverything = flagsEverything
    }

    public func scores(of _: String) -> [Float]? {
        AbusiveText.labels.map { $0 == "threat" && flagsEverything ? 1 : 0 }
    }
}
