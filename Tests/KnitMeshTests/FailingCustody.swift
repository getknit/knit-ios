import KnitStore
import KnitWire

@testable import KnitMesh

/// Fails the open unit, as a database error inside one fails it (``MemoryTransactor/failCurrentUnit()``).
private func failUnit(_ transactor: any StoreTransactor) {
    (transactor as? MemoryTransactor)?.failCurrentUnit()
}

/// A custody store whose reads or writes fail when told to, as a database that cannot read or write its file: a failing
/// read fails the open unit and answers the fallback the SQL store answers (nothing held), and a failing write answers
/// ``CustodyRefusal/writeFailed``. Everything else goes to the memory store it wraps, which the unit checkpoints.
final class FailingCustody: CustodyStore, @unchecked Sendable {
    let held: MemoryCustodyStore
    let transactor: any StoreTransactor
    /// Whether reads fail. Read on the engine's one thread only, as the stores are.
    var failsReads = false
    /// Whether writes fail.
    var failsWrites = false
    /// How many more live-frame reads (``frame(_:now:)``) succeed before they all fail; `nil` for no countdown.
    var framesReadBeforeFailing: Int?

    init(_ held: MemoryCustodyStore, transactor: any StoreTransactor) {
        self.held = held
        self.transactor = transactor
    }

    var limits: CustodyLimits { held.limits }

    func store(_ frame: CarriedFrame, origin: CustodyOrigin, now: Int64) -> CustodyStoreResult {
        guard !failsWrites else {
            failUnit(transactor)
            return .refused(.writeFailed)
        }
        return held.store(frame, origin: origin, now: now)
    }

    func liveFrames(now: Int64) -> [CarriedFrame] {
        guard !failsReads else {
            failUnit(transactor)
            return []
        }
        return held.liveFrames(now: now)
    }

    func liveIndex(now: Int64) -> [CustodyIndexEntry] { failsReads ? [] : held.liveIndex(now: now) }
    func liveIds(now: Int64) -> [String] { failsReads ? [] : held.liveIds(now: now) }

    func frame(_ id: String, now: Int64) -> CarriedFrame? {
        if let left = framesReadBeforeFailing {
            framesReadBeforeFailing = left - 1
            failsReads = failsReads || left <= 0
        }
        guard !failsReads else {
            failUnit(transactor)
            return nil
        }
        return held.frame(id, now: now)
    }

    func contains(_ id: String) -> Bool { failsReads ? false : held.contains(id) }
    func recipient(of id: String) -> String? { held.recipient(of: id) }
    func remove(_ id: String) { held.remove(id) }
    func sweepExpired(now: Int64) -> Int { held.sweepExpired(now: now) }
}

/// A block store whose id read fails when told to, failing the open unit and answering nobody, as SQL's fallback would.
final class FailingBlockReads: BlockStore, @unchecked Sendable {
    let held: any BlockStore
    let transactor: any StoreTransactor
    var failsReads = false

    init(_ held: any BlockStore, transactor: any StoreTransactor) {
        self.held = held
        self.transactor = transactor
    }

    func blockedNodeIds() -> Set<NodeId> {
        guard !failsReads else {
            failUnit(transactor)
            return []
        }
        return held.blockedNodeIds()
    }

    func isBlocked(deviceTag: String) -> Bool { held.isBlocked(deviceTag: deviceTag) }
    func block(_ nodeId: NodeId, deviceTag: String?) { held.block(nodeId, deviceTag: deviceTag) }
    func unblock(_ nodeId: NodeId, deviceTag: String?) { held.unblock(nodeId, deviceTag: deviceTag) }
}

/// A peer store whose row reads fail the open unit when told to, answering nobody, as SQL's fallback would.
final class FailingPeerUnit: PeerStore, @unchecked Sendable {
    let held: any PeerStore
    let transactor: any StoreTransactor
    var failsReads = false

    init(_ held: any PeerStore, transactor: any StoreTransactor) {
        self.held = held
        self.transactor = transactor
    }

    func peer(_ nodeId: NodeId) -> PeerRecord? {
        guard !failsReads else {
            failUnit(transactor)
            return nil
        }
        return held.peer(nodeId)
    }

    func upsert(_ peer: PeerRecord) { held.upsert(peer) }
    func verifiedNodeIds() -> Set<NodeId> { held.verifiedNodeIds() }
    func allPeers() -> [PeerRecord] { held.allPeers() }
    func recordProfileFrame(_ frame: WireEnvelope, of nodeId: NodeId, sentAt: Int64) {
        held.recordProfileFrame(frame, of: nodeId, sentAt: sentAt)
    }
    func profileFrame(of nodeId: NodeId) -> WireEnvelope? { held.profileFrame(of: nodeId) }
    func deleteProfileFrames(longerThan maxSignedBytes: Int) -> Int { held.deleteProfileFrames(longerThan: maxSignedBytes) }
}

/// A ratchet store whose session list fails when told to: ``RatchetSessions/dmScopes(now:)`` then answers `nil`.
final class FailingRatchetReads: RatchetStore, @unchecked Sendable {
    let held: any RatchetStore
    let transactor: any StoreTransactor
    var failsSessionList = false

    init(_ held: any RatchetStore, transactor: any StoreTransactor) {
        self.held = held
        self.transactor = transactor
    }

    func sessionPeerIds() -> [NodeId] {
        guard !failsSessionList else {
            failUnit(transactor)
            return []
        }
        return held.sessionPeerIds()
    }

    func session(_ peer: NodeId) -> RatchetSessionRecord? { held.session(peer) }
    func upsertSession(_ session: RatchetSessionRecord) { held.upsertSession(session) }
    func localEpochPrivateKey(_ peer: NodeId, epoch: Int) -> [UInt8]? { held.localEpochPrivateKey(peer, epoch: epoch) }
    func lowestLocalEpoch(_ peer: NodeId) -> Int? { held.lowestLocalEpoch(peer) }
    func recvEpochs(_ peer: NodeId, epoch: Int) -> [RatchetRecvEpochRecord] { held.recvEpochs(peer, epoch: epoch) }
    func skippedKeys(_ peer: NodeId, epoch: Int, index: Int) -> [RatchetSkippedKeyRecord] {
        held.skippedKeys(peer, epoch: epoch, index: index)
    }
    func applyOpen(_ delta: RatchetOpenDelta, from peer: NodeId, se: Int, n: Int) { held.applyOpen(delta, from: peer, se: se, n: n) }
    func commitSend(_ session: RatchetSessionRecord, newLocalEpoch: RatchetLocalEpochRecord?) {
        held.commitSend(session, newLocalEpoch: newLocalEpoch)
    }
    func purgeReceiveState(_ peer: NodeId) { held.purgeReceiveState(peer) }
    func deletePeer(_ peer: NodeId) { held.deletePeer(peer) }
    func records(of peer: NodeId) -> RatchetPeerRecords { held.records(of: peer) }
    func sweep(now: Int64) { held.sweep(now: now) }
}

extension MeshStores {
    /// These stores with any of custody, the blocks and the ratchet swapped for a wrapper over the store the transactor
    /// was made over, so a unit that is undone still puts it back.
    func replacing(custody: (any CustodyStore)? = nil, blocks: (any BlockStore)? = nil, ratchet: (any RatchetStore)? = nil) -> Self {
        MeshStores(
            custody: custody ?? self.custody,
            peers: peers,
            messages: messages,
            conversations: conversations,
            blocks: blocks ?? self.blocks,
            groups: groups,
            ownProfile: ownProfile,
            blobs: blobs,
            ratchet: ratchet ?? self.ratchet,
            groupRatchet: groupRatchet,
            presenceKeys: presenceKeys,
            transactor: transactor
        )
    }
}

/// Stores in memory whose custody, blocks and ratchet session list can be told to fail.
struct FailableStores {
    let stores: MeshStores
    let custody: FailingCustody
    let blocks: FailingBlockReads
    let ratchet: FailingRatchetReads
    let peers: FailingPeerUnit

    init() {
        let base = MeshStores.inMemory()
        guard let memory = base.custody as? MemoryCustodyStore else {
            preconditionFailure("in-memory stores keep custody in memory")
        }
        custody = FailingCustody(memory, transactor: base.transactor)
        blocks = FailingBlockReads(base.blocks, transactor: base.transactor)
        ratchet = FailingRatchetReads(base.ratchet, transactor: base.transactor)
        peers = FailingPeerUnit(base.peers, transactor: base.transactor)
        stores = base.replacing(custody: custody, blocks: blocks, ratchet: ratchet).replacing(peers: peers)
    }
}
