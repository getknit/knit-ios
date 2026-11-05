/// The sample chats' text filter (ADR 2026-11.pydf). The scene's own words answer as the scene says, so the sample opens
/// without loading the model and shows what it set out to show. Anything else is what the user typed, which meets the
/// bundled model as it would in a real chat: someone testing the filter here gets the filter's real answer.
public struct SampleTextClassifier: TextClassifier {
    private let scene: DemoTextClassifier
    private let words: Set<String>
    private let device: (any TextClassifier)?

    /// The filter for `scene`, with `device` the bundled model, or `nil` where a demo runs without it.
    public init(scene: DemoScene, device: (any TextClassifier)?) {
        self.scene = DemoTextClassifier(flagsEverything: false, flagging: scene.flaggedWords)
        words = scene.words
        self.device = device
    }

    public func scores(of text: String) async -> [Float]? {
        guard !words.contains(text) else {
            return scene.scores(of: text)
        }
        return await device?.scores(of: text)
    }
}
