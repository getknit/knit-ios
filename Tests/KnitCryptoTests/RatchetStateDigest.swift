import KnitTestSupport

@testable import KnitCrypto

/// A party's ratchet state for one peer, digested as `ratchet-v1.json` lists it (`TranscriptJson.state`, knit-next's
/// `TranscriptJson.kt:40-75`): secrets as SHA-256 hex, root tags as 16 hex digits, skipped keys as contiguous runs,
/// chains by epoch then tag, and our epochs the most recently minted first. Kotlin's `sendEpochExportSha256` is not
/// compared: this port keeps no export half (ADR 2026-10.5sk9).
struct RatchetStateDigest: Equatable {
    struct Session: Equatable {
        let rootSha256: String
        let confirmed: Bool
        let weAreInitiator: Bool
        let establishedAt: Int64
        let initEphPub: String?
        let initPkid: Int
        let peerInitEphPub: String?
        let peerBasePub: String?
        let peerBaseEpoch: Int
        let sendEpoch: Int
        let sendEpochPub: String?
        let sendChainKeySha256: String?
        let sendCount: Int
        let sendEpochStartedAt: Int64
        let sendEpochBaseEpoch: Int
        let highestPeAcked: Int
        let prevRootSha256: String?
        let prevRootWeAreInitiator: Bool
        let prevRootExpiresAt: Int64
        let lastResetSentAt: Int64
    }

    struct Chain: Equatable {
        let epoch: Int
        let rootTag: String
        let next: Int
        let chainKeySha256: String
        let lastUsedAt: Int64
    }

    struct Run: Equatable {
        let epoch: Int
        let rootTag: String
        let fromIndex: Int
        let toIndex: Int
    }

    struct Epoch: Equatable {
        let epoch: Int
        let createdAt: Int64
        let pub: String
    }

    let session: Session?
    let chains: [Chain]
    let skippedKeyCount: Int
    let skippedRuns: [Run]
    let localEpochs: [Epoch]
}

extension RatchetStateDigest {
    /// What the file states.
    init(_ state: RatchetVectors.TranscriptState) {
        session = state.session.map { stated in
            Session(
                rootSha256: stated.rootSha256,
                confirmed: stated.confirmed,
                weAreInitiator: stated.weAreInitiator,
                establishedAt: stated.establishedAt,
                initEphPub: stated.initEphPub,
                initPkid: stated.initPkid,
                peerInitEphPub: stated.peerInitEphPub,
                peerBasePub: stated.peerBasePub,
                peerBaseEpoch: stated.peerBaseEpoch,
                sendEpoch: stated.sendEpoch,
                sendEpochPub: stated.sendEpochPub,
                sendChainKeySha256: stated.sendChainKeySha256,
                sendCount: stated.sendCount,
                sendEpochStartedAt: stated.sendEpochStartedAt,
                sendEpochBaseEpoch: stated.sendEpochBaseEpoch,
                highestPeAcked: stated.highestPeAcked,
                prevRootSha256: stated.prevRootSha256,
                prevRootWeAreInitiator: stated.prevRootWeAreInitiator,
                prevRootExpiresAt: stated.prevRootExpiresAt,
                lastResetSentAt: stated.lastResetSentAt
            )
        }
        chains = state.recvEpochs.map { row in
            Chain(epoch: row.epoch, rootTag: row.rootTag, next: row.next, chainKeySha256: row.chainKeySha256, lastUsedAt: row.lastUsedAt)
        }
        skippedKeyCount = state.skippedKeyCount
        skippedRuns = state.skippedKeys.map { run in Run(epoch: run.epoch, rootTag: run.rootTag, fromIndex: run.fromIdx, toIndex: run.toIdx)
        }
        localEpochs = state.localEpochs.map { epoch in Epoch(epoch: epoch.epoch, createdAt: epoch.createdAt, pub: epoch.pub) }
    }

    /// What we hold.
    init(_ rows: RatchetRows) {
        session = rows.session.map(Self.session(of:))
        chains = rows.chains.values
            .sorted { lhs, rhs in (lhs.epoch, lhs.rootTag) < (rhs.epoch, rhs.rootTag) }
            .map(Self.chain(of:))
        let keys = rows.skippedKeys.values.sorted { lhs, rhs in (lhs.epoch, lhs.rootTag, lhs.index) < (rhs.epoch, rhs.rootTag, rhs.index) }
        skippedKeyCount = keys.count
        skippedRuns = Self.runs(of: keys)
        localEpochs = rows.localEpochs.values
            .sorted { lhs, rhs in (lhs.createdAt, lhs.epoch) > (rhs.createdAt, rhs.epoch) }
            .map { epoch in Epoch(epoch: epoch.epoch, createdAt: epoch.createdAt, pub: hexString(epoch.publicKey)) }
    }

    private static func session(of held: RatchetEngine.SessionState) -> Session {
        Session(
            rootSha256: sha256Hex(held.root),
            confirmed: held.confirmed,
            weAreInitiator: held.weAreInitiator,
            establishedAt: held.establishedAt,
            initEphPub: held.initEphPub.map(hexString),
            initPkid: held.initPkid,
            peerInitEphPub: held.peerInitEphPub.map(hexString),
            peerBasePub: held.peerBasePub.map(hexString),
            peerBaseEpoch: held.peerBaseEpoch,
            sendEpoch: held.sendEpoch,
            sendEpochPub: held.sendEpochPub.map(hexString),
            sendChainKeySha256: held.sendChainKey.map(sha256Hex),
            sendCount: held.sendCount,
            sendEpochStartedAt: held.sendEpochStartedAt,
            sendEpochBaseEpoch: held.sendEpochBaseEpoch,
            highestPeAcked: held.highestPeAcked,
            prevRootSha256: held.prevRoot.map(sha256Hex),
            prevRootWeAreInitiator: held.prevRootWeAreInitiator,
            prevRootExpiresAt: held.prevRootExpiresAt,
            lastResetSentAt: held.lastResetSentAt
        )
    }

    private static func chain(of row: RatchetEngine.RecvEpoch) -> Chain {
        Chain(
            epoch: row.epoch,
            rootTag: tagHex(row.rootTag),
            next: row.next,
            chainKeySha256: sha256Hex(row.chainKey),
            lastUsedAt: row.lastUsedAt
        )
    }

    /// Sorted keys as runs of contiguous indices per `(epoch, rootTag)` (`skippedRuns`, `TranscriptJson.kt:103-130`).
    private static func runs(of keys: [RatchetEngine.SkippedKey]) -> [Run] {
        var runs: [Run] = []
        for key in keys {
            let tag = tagHex(key.rootTag)
            if let last = runs.last, last.epoch == key.epoch, last.rootTag == tag, last.toIndex + 1 == key.index {
                runs[runs.count - 1] = Run(epoch: last.epoch, rootTag: tag, fromIndex: last.fromIndex, toIndex: key.index)
            } else {
                runs.append(Run(epoch: key.epoch, rootTag: tag, fromIndex: key.index, toIndex: key.index))
            }
        }
        return runs
    }
}
