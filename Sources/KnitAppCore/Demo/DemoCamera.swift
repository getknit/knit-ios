/// A camera that can scan and answers one thing: `-seedDemo`'s, under `-demoCamera`.
public struct DemoCamera: CameraAccess {
    /// What it answers.
    public enum Answer: Sendable, Equatable, CaseIterable {
        /// The permission is refused.
        case denied
        /// The permission is given, so the scanner tries to start.
        case allowed
    }

    private let answer: Answer

    /// A camera that answers `answer`.
    public init(_ answer: Answer) {
        self.answer = answer
    }

    public func canScan() -> Bool {
        true
    }

    public func authorization() -> CameraAuthorization {
        answer == .allowed ? .allowed : .denied
    }

    public func request() -> CameraAuthorization {
        authorization()
    }
}
