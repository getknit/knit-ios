import KnitCrypto
import KnitStore
import KnitSync
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The group form's receive side against the switch and the clock (ADR 2026-10.5sk9, phase P6a2): with the switch off
/// nothing changes, and with it on the group store's sweep and the group custody replay run at start and then once an
/// hour, as Android's heal runs them past their floors (`HealFloors`, `MeshManager.kt:3510-3511`).
@Suite struct MeshEngineGroupRatchetScheduleTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)

    private var now: Int64 { EngineFixture.start }
    private static let hour: Int64 = 3_600_000

    /// The switch off: a seed DM and a group-form frame drop unopened as before, nothing reaches the group store, and nothing
    /// goes on the air.
    @Test func withTheSwitchOffTheGroupFormDropsUnopenedAndNothingIsStoredOrSent() throws {
        let fixture = EngineFixture(me)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        let group = fixture.holdGroup(with: [alice])
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        let ours = try SignedPrekey.mint(id: 1, signedBy: me.keys, createdAt: 0)
        let prekey = try #require(PeerPrekey(verifying: ours.info, signedBy: me.keys.bundle))
        let author = GroupFormAuthor(android, in: group.id)
        fixture.deliver(try author.seedDm(to: me, prekey: prekey, id: "off-seed", sentAt: now), from: android)
        for index in 0..<3 {
            fixture.deliver(try author.frame(group, id: "off-g\(index)", body: "x", sentAt: now), from: alice)
        }
        fixture.advance(Self.hour)
        #expect(fixture.engine.dropped[.cannotOpen] == 4)
        #expect(fixture.engine.dropped[.groupRatchetNoKey] == nil)
        #expect(fixture.stores.groupRatchet.holdings(of: group.id) == .empty)
        #expect(fixture.engine.pendingGroupKeys.isEmpty && fixture.engine.groupCounts == RatchetGroupCounts())
        #expect(
            fixture.transport.written(.chat).allSatisfy { ExactKey($0.envelope.senderId) != ExactKey(me.nodeId.string) }, "nothing of ours")
        #expect(fixture.stores.custody.contains("off-seed") && fixture.stores.custody.contains("off-g0"), "still carried")
    }

    /// A group sweep the store refuses is logged and changes nothing else, as the DM ratchet's is.
    @Test func aGroupSweepTheStoreRefusesIsLogged() throws {
        let refusing = RefusingGroupRatchetStore()
        refusing.refuse(.writes)
        let stores = MeshStores.inMemory().replacing(groupRatchet: refusing, transactor: refusing.transactor)
        let fixture = try EngineFixture.ratcheting(me, stores: stores)
        #expect(fixture.log.all.contains { $0.contains("mesh group ratchet sweep failed") }, "the start's sweep")
        #expect(fixture.engine.isStarted)
    }

    /// knit-next's `healRunsTheRetentionSweepsAndTheCustodyReplayOncePastTheirHourNotOnEveryCall` (`MeshManagerTest.kt:2744`):
    /// the start sweeps both ratchets and replays group custody once; a heal inside the hour leaves both to the next; the
    /// floor counts from the last run.
    @Test func healRunsTheRetentionSweepsAndTheCustodyReplayOncePastTheirHourNotOnEveryCall() throws {
        let memory = MeshStores.inMemory()
        let counting = CountingGroupRatchetStore(memory.groupRatchet)
        let fixture = try EngineFixture.ratcheting(me, stores: memory.replacing(groupRatchet: counting))
        func replays() -> Int { fixture.log.all.count { $0.contains("mesh group custody replay:") } }
        #expect(counting.sweeps == 1 && replays() == 1, "the start's own pass")
        fixture.advance(Self.hour / 4)
        #expect(counting.sweeps == 1 && replays() == 1, "a heal inside the hour leaves both to the next")
        fixture.advance(Self.hour)
        #expect(counting.sweeps == 2 && replays() == 2)
        fixture.advance(Self.hour - 1)
        #expect(counting.sweeps == 2 && replays() == 2, "the floor is measured from the last run, not the last heal")
    }
}

extension MeshStores {
    /// These stores with the group store swapped for `groupRatchet`, under `transactor`.
    func replacing(groupRatchet: any GroupRatchetStore, transactor: any StoreTransactor) -> Self {
        MeshStores(
            custody: custody,
            peers: peers,
            messages: messages,
            conversations: conversations,
            blocks: blocks,
            groups: groups,
            ownProfile: ownProfile,
            blobs: blobs,
            ratchet: ratchet,
            groupRatchet: groupRatchet,
            transactor: transactor
        )
    }

    /// These stores with the group store swapped for `groupRatchet`, a wrapper over the store the transactor was made over,
    /// so a unit that is undone still puts it back.
    func replacing(groupRatchet: any GroupRatchetStore) -> Self {
        MeshStores(
            custody: custody,
            peers: peers,
            messages: messages,
            conversations: conversations,
            blocks: blocks,
            groups: groups,
            ownProfile: ownProfile,
            blobs: blobs,
            ratchet: ratchet,
            groupRatchet: groupRatchet,
            transactor: transactor
        )
    }
}

/// A group store that counts its sweeps, over a memory store the transactor already covers.
private final class CountingGroupRatchetStore: GroupRatchetStore {
    let held: any GroupRatchetStore
    private let swept = Lock(0)

    var sweeps: Int { swept.withLock { $0 } }

    init(_ held: any GroupRatchetStore) {
        self.held = held
    }

    func sendChain(_ group: String) -> GroupSendChainRecord? { held.sendChain(group) }
    func sendChains(_ group: String) -> [GroupSendChainRecord] { held.sendChains(group) }
    func commitSend(_ chain: GroupSendChainRecord, in group: String) { held.commitSend(chain, in: group) }
    func retireSendChains(_ group: String) { held.retireSendChains(group) }
    func recvChains(_ group: String, from sender: NodeId, epoch: Int) -> [GroupRecvChainRecord] {
        held.recvChains(group, from: sender, epoch: epoch)
    }
    func skippedKeys(_ group: String, from sender: NodeId, epoch: Int, index: Int) -> [GroupSkippedKeyRecord] {
        held.skippedKeys(group, from: sender, epoch: epoch, index: index)
    }
    func insertRecvChain(_ chain: GroupRecvChainRecord, in group: String, from sender: NodeId) {
        held.insertRecvChain(chain, in: group, from: sender)
    }
    func applyOpen(_ delta: GroupOpenDelta, in group: String, from sender: NodeId, se: Int, n: Int) {
        held.applyOpen(delta, in: group, from: sender, se: se, n: n)
    }
    func purgeGroup(_ group: String) { held.purgeGroup(group) }
    func keySend(_ group: String, member: NodeId) -> GroupKeySendRecord? { held.keySend(group, member: member) }
    func keySends(_ group: String) -> [GroupKeySendRecord] { held.keySends(group) }
    func markKeySent(_ group: String, to member: NodeId, epoch: Int, at: Int64) {
        held.markKeySent(group, to: member, epoch: epoch, at: at)
    }
    func markKeyAcked(_ group: String, by member: NodeId, epoch: Int, at: Int64) {
        held.markKeyAcked(group, by: member, epoch: epoch, at: at)
    }
    func deleteKeySend(_ group: String, member: NodeId) { held.deleteKeySend(group, member: member) }
    func holdings(of group: String) -> GroupRatchetHoldings { held.holdings(of: group) }
    func sweep(now: Int64) {
        swept.withLock { $0 += 1 }
        held.sweep(now: now)
    }
}
