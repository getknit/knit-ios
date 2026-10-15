/// A store that a ``MemoryTransactor`` can roll back: it copies everything it holds, and can put that copy back.
///
/// A memory store keeps its state as one value behind a `Lock` (two, for the peers and their proofs), so a checkpoint
/// is a copy of that value, which costs nothing until the store next changes, and a restore is one assignment.
public protocol Checkpointing: AnyObject, Sendable {
    /// Everything the store holds now, ready to be put back.
    func checkpoint() -> StoreCheckpoint
}

/// What one store held at one moment (``Checkpointing/checkpoint()``).
public struct StoreCheckpoint: Sendable {
    private let restoring: @Sendable () -> Void

    /// A checkpoint that `restoring` puts back.
    @preconcurrency
    public init(restoring: @escaping @Sendable () -> Void) {
        self.restoring = restoring
    }

    /// Puts the store back as it was when the checkpoint was taken.
    public func restore() {
        restoring()
    }
}
