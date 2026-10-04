/// The demo's content filter: every photo scores as porn under `-demoSensitive`, and as neutral otherwise, whatever it
/// shows. The demo's photos are painted, and nothing in the repository is explicit.
public struct DemoPhotoClassifier: PhotoClassifier {
    /// Whether every photo looks explicit.
    public let flagsEverything: Bool

    /// A classifier that finds every photo explicit when `flagsEverything`, and none otherwise.
    public init(flagsEverything: Bool) {
        self.flagsEverything = flagsEverything
    }

    public func scores(of _: [UInt8]) -> [Float]? {
        flagsEverything ? [0, 0, 0, 1, 0] : [0, 0, 1, 0, 0]
    }
}
