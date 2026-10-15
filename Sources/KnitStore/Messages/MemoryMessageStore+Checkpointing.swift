import KnitSync

// Apart from the class only to keep its file inside the lint's length.
extension MemoryMessageStore: Checkpointing {
    /// Every row with its order and unread flag, the deleted ids and the reactions, together.
    public func checkpoint() -> StoreCheckpoint {
        let held = state.withLock { $0 }
        return StoreCheckpoint { [self] in state.withLock { $0 = held } }
    }
}
