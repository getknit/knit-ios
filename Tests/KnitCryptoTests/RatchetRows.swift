import KnitWire

@testable import KnitCrypto

/// The ratchet rows one device keeps for one peer, with the row rules of knit-next's `RatchetRepository` over
/// `RatchetDao` (`RatchetRepository.kt:54-102`, `RatchetDao.kt:43-102`): the session and the receive chains upsert, a
/// local epoch minted again replaces the dead era's key of its number (knit-next ADR 027), skipped keys are inserted
/// only where none is stored, and a spent key goes by its own root's tag. What P4c's store will do, in memory, so the
/// engine's tests apply its deltas the way production will.
struct RatchetRows {
    /// A receive chain's key: `(peer, epoch, rootTag)` in `ratchet_recv_epochs`, for one peer.
    struct ChainKey: Hashable {
        let epoch: Int
        let rootTag: Int64
    }

    /// A skipped key's key: `(peer, epoch, idx, rootTag)` in `ratchet_skipped_keys`, for one peer.
    struct SkippedKeyId: Hashable {
        let epoch: Int
        let index: Int
        let rootTag: Int64
    }

    var session: RatchetEngine.SessionState?
    var localEpochs: [Int: RatchetEngine.LocalEpoch] = [:]
    var chains: [ChainKey: RatchetEngine.RecvEpoch] = [:]
    var skippedKeys: [SkippedKeyId: RatchetEngine.SkippedKey] = [:]

    /// `commitSend` (`RatchetRepository.kt:94-104`): the session, and the epoch a seal started, replacing any of its
    /// number.
    mutating func commitSend(_ state: RatchetEngine.SessionState, newLocalEpoch: RatchetEngine.LocalEpoch?) {
        session = state
        if let newLocalEpoch {
            localEpochs[newLocalEpoch.epoch] = newLocalEpoch
        }
    }

    /// `applyOpen` (`RatchetRepository.kt:54-92`), in its order: the purge, the session, the chain, the skipped keys
    /// inserted if absent, then the spent key at the header's `(se, n)` deleted by its own tag.
    mutating func apply(_ delta: RatchetEngine.OpenDelta, se: Int, n: Int) {
        if delta.purgePeerRecvState {
            purgeReceiveState()
        }
        session = delta.session
        if let chain = delta.recvEpoch {
            chains[ChainKey(epoch: chain.epoch, rootTag: chain.rootTag)] = chain
        }
        for key in delta.skippedInserts {
            let id = SkippedKeyId(epoch: key.epoch, index: key.index, rootTag: key.rootTag)
            if skippedKeys[id] == nil {
                skippedKeys[id] = key
            }
        }
        if let tag = delta.consumedSkippedTag {
            skippedKeys[SkippedKeyId(epoch: se, index: n, rootTag: tag)] = nil
        }
    }

    /// Every receive chain and skipped key held for the peer, gone (`purgePeerRecvState`).
    mutating func purgeReceiveState() {
        chains = [:]
        skippedKeys = [:]
    }

    /// What `RatchetSessions.contextFor` reads for a frame (`RatchetSessions.kt:124-140`): every chain for its `se`,
    /// every skipped key for its `(se, n)`, whatever root derived them.
    func chains(for header: RatchetHeader) -> [RatchetEngine.RecvEpoch] {
        chains.values.filter { $0.epoch == header.se }
    }

    /// See ``chains(for:)``.
    func skippedKeys(for header: RatchetHeader) -> [RatchetEngine.SkippedKey] {
        skippedKeys.values.filter { $0.epoch == header.se && $0.index == header.n }
    }

    /// Our epoch the header names, by number alone, when `pe ≥ 1`.
    func ownBasePrivateKey(for header: RatchetHeader) -> [UInt8]? {
        header.pe >= 1 ? localEpochs[header.pe]?.privateKey : nil
    }
}

extension RatchetEngine.OpenOutcome {
    /// The failure, or `nil` for a frame that opened.
    var failure: Failed? {
        guard case .failed(let failure) = self else {
            return nil
        }
        return failure
    }

    /// What opened, or `nil`.
    var opened: Opened? {
        guard case .opened(let opened) = self else {
            return nil
        }
        return opened
    }

    /// The vector file's name for the outcome: `OPENED`, or Kotlin's `OpenOutcome.Failed` name.
    var vectorName: String {
        switch self {
        case .opened:
            "OPENED"
        case .failed(.noSession):
            "NO_SESSION"
        case .failed(.epochGone):
            "EPOCH_GONE"
        case .failed(.duplicate):
            "DUPLICATE"
        case .failed(.badHeader):
            "BAD_HEADER"
        case .failed(.aeadFail):
            "AEAD_FAIL"
        }
    }
}

extension NodeId {
    /// A canonical id that sorts by `letter`: 25 of it and a final `a`, whose padding bits are zero.
    static func repeating(_ letter: Character) -> NodeId {
        guard let id = NodeId(String(repeating: letter, count: Self.length - 1) + "a") else {
            preconditionFailure("a lowercase base32 letter makes a canonical id")
        }
        return id
    }
}
