/// The demo's content filter: every photo scores as porn under `-demoSensitive`, and so does a photo whose bytes a scene
/// names for it to flag (``DemoScene/flaggedPhotos``); everything else scores as neutral, whatever it shows. The demo's
/// faces and photos are chosen to be safe for work, and nothing in the repository is explicit: a scene that shows the
/// filter at work flags an ordinary photo, which it never shows.
public struct DemoPhotoClassifier: PhotoClassifier {
    /// Whether every photo looks explicit.
    public let flagsEverything: Bool
    /// The photos, byte for byte, that look explicit when not everything does.
    public let flagging: Set<[UInt8]>

    /// A classifier that finds every photo explicit when `flagsEverything`, and otherwise only `flagging`.
    public init(flagsEverything: Bool, flagging: Set<[UInt8]> = []) {
        self.flagsEverything = flagsEverything
        self.flagging = flagging
    }

    public func scores(of bytes: [UInt8]) -> [Float]? {
        flagsEverything || flagging.contains(bytes) ? [0, 0, 0, 1, 0] : [0, 0, 1, 0, 0]
    }
}
