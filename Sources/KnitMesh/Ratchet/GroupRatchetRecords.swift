public import KnitCrypto
public import KnitStore

/// The one place KnitStore's group records meet KnitCrypto's group engine types (ADR 2026-10.5sk9): `GroupRatchetRepository`'s
/// `toChain` and `toEntity` (knit-next `data/ratchet/GroupRatchetRepository.kt:183-224`, at `cbf2a487`). KnitStore does not
/// depend on KnitCrypto, so its rows hold bytes and numbers, and the group and sender a row belongs to are the store
/// call's. Every field goes both ways; `GroupRatchetSessionsTests` round-trips each through both stores.
public enum GroupRatchetRecords {
    /// The send chain a row holds.
    public static func sendChain(_ record: GroupSendChainRecord) -> GroupRatchetEngine.SendChain {
        GroupRatchetEngine.SendChain(
            epoch: record.epoch, seed: record.seed, chainKey: record.chainKey, count: record.count, mintedAt: record.mintedAt)
    }

    /// The row that holds `chain`.
    public static func record(_ chain: GroupRatchetEngine.SendChain) -> GroupSendChainRecord {
        GroupSendChainRecord(epoch: chain.epoch, seed: chain.seed, chainKey: chain.chainKey, count: chain.count, mintedAt: chain.mintedAt)
    }

    /// The receive chain a row holds.
    public static func recvChain(_ record: GroupRecvChainRecord) -> GroupRatchetEngine.RecvChain {
        GroupRatchetEngine.RecvChain(
            epoch: record.epoch, mintedAt: record.mintedAt, chainKey: record.chainKey, next: record.next, lastUsedAt: record.lastUsedAt)
    }

    /// The row that holds `chain`.
    public static func record(_ chain: GroupRatchetEngine.RecvChain) -> GroupRecvChainRecord {
        GroupRecvChainRecord(
            epoch: chain.epoch, mintedAt: chain.mintedAt, chainKey: chain.chainKey, next: chain.next, lastUsedAt: chain.lastUsedAt)
    }

    /// The skipped key a row holds.
    public static func skippedKey(_ record: GroupSkippedKeyRecord) -> GroupRatchetEngine.SkippedKey {
        GroupRatchetEngine.SkippedKey(
            epoch: record.epoch, mintedAt: record.mintedAt, index: record.index, messageKey: record.messageKey, createdAt: record.createdAt)
    }

    /// The row that holds `key`.
    public static func record(_ key: GroupRatchetEngine.SkippedKey) -> GroupSkippedKeyRecord {
        GroupSkippedKeyRecord(
            epoch: key.epoch, mintedAt: key.mintedAt, index: key.index, messageKey: key.messageKey, createdAt: key.createdAt)
    }

    /// The rows an open's `delta` writes.
    public static func record(_ delta: GroupRatchetEngine.OpenDelta) -> GroupOpenDelta {
        GroupOpenDelta(
            recvChain: delta.recvChain.map { record($0) },
            skippedInserts: delta.skippedInserts.map { record($0) },
            consumedSkippedMintedAt: delta.consumedSkippedMintedAt
        )
    }
}
