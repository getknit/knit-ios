/// The sample chats' photo filter (ADR 2026-11.pydf): the photos the scene flags look explicit, and any other photo, the
/// user's among them, meets the bundled model.
public struct SamplePhotoClassifier: PhotoClassifier {
    private let flagged: DemoPhotoClassifier
    private let device: (any PhotoClassifier)?

    /// The filter that flags `flagging`, byte for byte, with `device` the bundled model, or `nil` where a demo runs
    /// without it.
    public init(flagging: Set<[UInt8]>, device: (any PhotoClassifier)?) {
        flagged = DemoPhotoClassifier(flagsEverything: false, flagging: flagging)
        self.device = device
    }

    public func scores(of bytes: [UInt8]) async -> [Float]? {
        guard !flagged.flagging.contains(bytes) else {
            return flagged.scores(of: bytes)
        }
        return await device?.scores(of: bytes)
    }
}
