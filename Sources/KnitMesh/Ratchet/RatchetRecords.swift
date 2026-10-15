public import KnitCrypto
public import KnitStore

/// The one place KnitStore's ratchet records meet KnitCrypto's engine types (ADR 2026-10.5sk9): `RatchetRepository`'s
/// `toState` and `toEntity` (knit-next `data/ratchet/RatchetRepository.kt:159-210`, at `ac491f4c`). KnitStore does not
/// depend on KnitCrypto, so its rows hold bytes, numbers, flags and node ids.
///
/// Every field goes both ways. A session that came back without its send chain or, unconfirmed, its init would make the
/// engine's `seal` answer `nil`, and every DM after it would quietly go as v1; `RatchetRecordsTests` round-trips each
/// field through both stores.
public enum RatchetRecords {
    /// The session a row holds.
    public static func session(_ record: RatchetSessionRecord) -> RatchetEngine.SessionState {
        RatchetEngine.SessionState(
            peerId: record.peerId,
            confirmed: record.confirmed,
            weAreInitiator: record.weAreInitiator,
            root: record.root,
            prevRoot: record.prevRoot,
            prevRootWeAreInitiator: record.prevRootWeAreInitiator,
            prevRootExpiresAt: record.prevRootExpiresAt,
            establishedAt: record.establishedAt,
            initEphPub: record.initEphPub,
            initPkid: record.initPkid,
            peerInitEphPub: record.peerInitEphPub,
            peerBasePub: record.peerBasePub,
            peerBaseEpoch: record.peerBaseEpoch,
            sendEpoch: record.sendEpoch,
            sendEpochPub: record.sendEpochPub,
            sendChainKey: record.sendChainKey,
            sendCount: record.sendCount,
            sendEpochStartedAt: record.sendEpochStartedAt,
            sendEpochBaseEpoch: record.sendEpochBaseEpoch,
            highestPeAcked: record.highestPeAcked,
            lastResetSentAt: record.lastResetSentAt
        )
    }

    /// The row that holds `session`.
    public static func record(_ session: RatchetEngine.SessionState) -> RatchetSessionRecord {
        RatchetSessionRecord(
            peerId: session.peerId,
            confirmed: session.confirmed,
            weAreInitiator: session.weAreInitiator,
            root: session.root,
            prevRoot: session.prevRoot,
            prevRootWeAreInitiator: session.prevRootWeAreInitiator,
            prevRootExpiresAt: session.prevRootExpiresAt,
            establishedAt: session.establishedAt,
            initEphPub: session.initEphPub,
            initPkid: session.initPkid,
            peerInitEphPub: session.peerInitEphPub,
            peerBasePub: session.peerBasePub,
            peerBaseEpoch: session.peerBaseEpoch,
            sendEpoch: session.sendEpoch,
            sendEpochPub: session.sendEpochPub,
            sendChainKey: session.sendChainKey,
            sendCount: session.sendCount,
            sendEpochStartedAt: session.sendEpochStartedAt,
            sendEpochBaseEpoch: session.sendEpochBaseEpoch,
            highestPeAcked: session.highestPeAcked,
            lastResetSentAt: session.lastResetSentAt
        )
    }

    /// The epoch pair a row holds.
    public static func localEpoch(_ record: RatchetLocalEpochRecord) -> RatchetEngine.LocalEpoch {
        RatchetEngine.LocalEpoch(
            epoch: record.epoch, privateKey: record.privateKey, publicKey: record.publicKey, createdAt: record.createdAt)
    }

    /// The row that holds `epoch`.
    public static func record(_ epoch: RatchetEngine.LocalEpoch) -> RatchetLocalEpochRecord {
        RatchetLocalEpochRecord(epoch: epoch.epoch, privateKey: epoch.privateKey, publicKey: epoch.publicKey, createdAt: epoch.createdAt)
    }

    /// The receive chain a row holds.
    public static func recvEpoch(_ record: RatchetRecvEpochRecord) -> RatchetEngine.RecvEpoch {
        RatchetEngine.RecvEpoch(
            epoch: record.epoch,
            rootTag: record.rootTag,
            chainKey: record.chainKey,
            next: record.next,
            lastUsedAt: record.lastUsedAt
        )
    }

    /// The row that holds `chain`.
    public static func record(_ chain: RatchetEngine.RecvEpoch) -> RatchetRecvEpochRecord {
        RatchetRecvEpochRecord(
            epoch: chain.epoch, rootTag: chain.rootTag, chainKey: chain.chainKey, next: chain.next, lastUsedAt: chain.lastUsedAt)
    }

    /// The skipped key a row holds.
    public static func skippedKey(_ record: RatchetSkippedKeyRecord) -> RatchetEngine.SkippedKey {
        RatchetEngine.SkippedKey(
            epoch: record.epoch,
            rootTag: record.rootTag,
            index: record.index,
            messageKey: record.messageKey,
            createdAt: record.createdAt
        )
    }

    /// The row that holds `key`.
    public static func record(_ key: RatchetEngine.SkippedKey) -> RatchetSkippedKeyRecord {
        RatchetSkippedKeyRecord(
            epoch: key.epoch, rootTag: key.rootTag, index: key.index, messageKey: key.messageKey, createdAt: key.createdAt)
    }

    /// The rows an open's `delta` writes.
    public static func record(_ delta: RatchetEngine.OpenDelta) -> RatchetOpenDelta {
        RatchetOpenDelta(
            session: record(delta.session),
            recvEpoch: delta.recvEpoch.map { record($0) },
            skippedInserts: delta.skippedInserts.map { record($0) },
            consumedSkippedTag: delta.consumedSkippedTag,
            purgePeerRecvState: delta.purgePeerRecvState
        )
    }
}
