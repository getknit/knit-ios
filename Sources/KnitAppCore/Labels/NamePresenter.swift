/// What someone else's stored name, status or group name is drawn as (`NamePresenter` in knit-next's `PeerLabels.kt`):
/// as it is, or blank when the content filter hides it (``ShownNames``, ADR 2026-11.y4pc there). A blank name then takes
/// the alias path that a name of invisible characters already takes. The stored text is never changed.
public struct NamePresenter: Sendable {
    /// Every name as it is stored: the content filter off, or no screen.
    public static let asStored = Self { $0 }

    private let present: @Sendable (String) -> String

    /// A presenter that draws a stored text as `present` answers.
    @preconcurrency
    public init(_ present: @escaping @Sendable (String) -> String) {
        self.present = present
    }

    /// What `stored` is drawn as.
    public func callAsFunction(_ stored: String) -> String {
        present(stored)
    }
}
