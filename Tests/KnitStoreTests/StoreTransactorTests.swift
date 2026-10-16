import KnitStore
import KnitTestSupport
import KnitWire
import Synchronization
import Testing

/// Counts the errors a database reported, for the tests that expect one.
final class FailureCount: Sendable {
    private let count = Atomic(0)

    var value: Int { count.load(ordering: .sequentiallyConsistent) }

    @Sendable func record(_: any Error) {
        count.wrappingAdd(1, ordering: .sequentiallyConsistent)
    }
}

/// A group store in memory whose saves fail as a database's write can: nothing is kept, and the unit it ran in fails.
private final class RefusingGroupStore: GroupStore {
    private let held: any GroupStore
    private let unit: MemoryTransactor

    init(held: any GroupStore, unit: MemoryTransactor) {
        self.held = held
        self.unit = unit
    }

    func group(_ id: String) -> GroupRecord? {
        held.group(id)
    }

    func groups() -> [GroupRecord] {
        held.groups()
    }

    func save(_: GroupRecord) {
        unit.failCurrentUnit()
    }
}

/// The store unit a ratchet change commits in with everything it carries, or not at all (ADR 2026-10.5sk9), run against
/// every store kind. A session's advance stands in for a store write here, since its store is the next phase's: a unit
/// that kept one write while another failed would spend a message's key with no row to show for it.
@Suite struct StoreTransactorTests {
    private static let kinds = RepositoryKind.allCases

    private let alice = fixtureNodeId(1)
    private let bob = fixtureNodeId(2)
    private let carol = fixtureNodeId(3)
    private let groupId = "g-0123456789abcdef01234567"

    @Test(arguments: kinds)
    func aUnitsWritesAcrossEveryStoreStandTogetherWhenItCommits(kind: RepositoryKind) throws {
        let stores = try kind.make()
        seed(stores)
        let outcome = stores.transactor.atomically { () -> String? in
            changePeopleAndMessages(stores)
            changeGroupAndProfile(stores)
            changeCustody(stores)
            return "deliver m2"
        }
        let expected = try withoutAUnit(kind, [changePeopleAndMessages, changeGroupAndProfile, changeCustody])
        #expect(outcome == .committed("deliver m2"))
        #expect(contents(stores) == expected)
    }

    @Test(arguments: kinds)
    func aUnitThatAbandonsLeavesEveryStoreAsItWas(kind: RepositoryKind) throws {
        let stores = try kind.make()
        seed(stores)
        let before = contents(stores)
        let outcome = stores.transactor.atomically { () -> String? in
            changePeopleAndMessages(stores)
            changeGroupAndProfile(stores)
            changeCustody(stores)
            return nil
        }
        #expect(outcome == .abandoned)
        #expect(contents(stores) == before)
    }

    @Test(arguments: kinds, ["deliver m2", nil] as [String?])
    func aWriteThatFailsUndoesEveryOtherWriteInTheUnit(kind: RepositoryKind, answer: String?) throws {
        // The writes before the failure stand for a session's advance, and those after for the row it carried and the
        // acks inline with it: none of them may stand once one write failed, and nothing may be delivered. A body that
        // then answers nil has not abandoned a sound unit: the unit failed, and says so.
        let failures = FailureCount()
        var stores = try kind.make(failures: failures.record)
        seed(stores)
        let before = contents(stores)
        try refuseGroupWritesInMemory(kind, in: &stores)
        let outcome = stores.transactor.atomically { [stores] () -> String? in
            changePeopleAndMessages(stores)
            failingWrite(stores)
            changeGroupAndProfile(stores)
            changeCustody(stores)
            return answer
        }
        #expect(outcome == .failed)
        #expect(contents(stores) == before)
        #expect(failures.value == (kind == .sql ? 1 : 0), "the database reports its error once, the unit's failure with it")
    }

    @Test(arguments: kinds)
    func everyUnitAboveTheOutermostAnswersJoinedAndOnlyTheOutermostCommitted(kind: RepositoryKind) throws {
        let stores = try kind.make()
        var middle: Transacted<Int>?
        var inner: Transacted<Int>?
        let outcome = stores.transactor.atomically { () -> Int? in
            middle = stores.transactor.atomically { () -> Int? in
                inner = stores.transactor.atomically { () -> Int? in
                    stores.conversations.accept("inner")
                    return 3
                }
                return 2
            }
            return 1
        }
        #expect(inner == .joined(3), "its writes wait on the outermost, so its work goes up, never out")
        #expect(middle == .joined(2))
        #expect(outcome == .committed(1))
        #expect(stores.conversations.acceptedConversations() == ["inner"])
        #expect(stores.transactor.atomically { () -> Int? in 4 } == .committed(4), "the next unit is outermost again")
    }

    @Test(arguments: kinds)
    func aNestedUnitJoinsTheOuterOneAndStandsOrFallsWithIt(kind: RepositoryKind) throws {
        for commits in [true, false] {
            let stores = try kind.make()
            seed(stores)
            let before = contents(stores)
            var inner: Transacted<Int>?
            let outcome = stores.transactor.atomically { () -> String? in
                changePeopleAndMessages(stores)
                inner = stores.transactor.atomically { () -> Int? in
                    changeGroupAndProfile(stores)
                    return 1
                }
                changeCustody(stores)
                return commits ? "deliver" : nil
            }
            #expect(inner == .joined(1), "it joined the outer unit, whose commit alone makes its writes stand")
            if commits {
                let expected = try withoutAUnit(kind, [changePeopleAndMessages, changeGroupAndProfile, changeCustody])
                #expect(outcome == .committed("deliver"))
                #expect(contents(stores) == expected)
            } else {
                #expect(outcome == .abandoned)
                #expect(contents(stores) == before, "what the nested unit wrote went with the outer one")
            }
        }
    }

    @Test(arguments: kinds)
    func aNestedUnitThatAbandonsUndoesOnlyItsOwnWrites(kind: RepositoryKind) throws {
        let stores = try kind.make()
        seed(stores)
        var inner: Transacted<Int>?
        let outcome = stores.transactor.atomically { () -> String? in
            changePeopleAndMessages(stores)
            inner = stores.transactor.atomically { () -> Int? in
                changeGroupAndProfile(stores)
                return nil
            }
            changeCustody(stores)
            return "deliver"
        }
        let expected = try withoutAUnit(kind, [changePeopleAndMessages, changeCustody])
        #expect(inner == .abandoned)
        #expect(outcome == .committed("deliver"))
        #expect(contents(stores) == expected)
    }

    @Test(arguments: kinds)
    func aFailureInsideANestedUnitFailsTheOutermost(kind: RepositoryKind) throws {
        let failures = FailureCount()
        var stores = try kind.make(failures: failures.record)
        seed(stores)
        let before = contents(stores)
        try refuseGroupWritesInMemory(kind, in: &stores)
        var inner: Transacted<Int>?
        let outcome = stores.transactor.atomically { [stores] () -> String? in
            changePeopleAndMessages(stores)
            inner = stores.transactor.atomically { () -> Int? in
                failingWrite(stores)
                return 1
            }
            changeCustody(stores)
            return "deliver"
        }
        #expect(inner == .failed)
        #expect(outcome == .failed, "the outer body answered work, and the unit still failed")
        #expect(contents(stores) == before)
        #expect(failures.value == (kind == .sql ? 1 : 0))
    }

    @Test(arguments: kinds)
    func aUnitThatHasFailedRunsNoUnitInsideIt(kind: RepositoryKind) throws {
        var stores = try kind.make { _ in
            // The refused write's error, which the other tests count.
        }
        seed(stores)
        try refuseGroupWritesInMemory(kind, in: &stores)
        var ran = false
        var inner: Transacted<Int>?
        let outcome = stores.transactor.atomically { [stores] () -> String? in
            failingWrite(stores)
            inner = stores.transactor.atomically { () -> Int? in
                ran = true
                return 1
            }
            return "deliver"
        }
        #expect(inner == .failed)
        #expect(!ran, "its body never ran")
        #expect(outcome == .failed)
    }

    @Test(arguments: kinds)
    func aReadInsideAUnitSeesTheUnitsOwnWrites(kind: RepositoryKind) throws {
        let stores = try kind.make()
        seed(stores)
        let before = contents(stores)
        let outcome = stores.transactor.atomically { () -> Int? in
            changePeopleAndMessages(stores)
            changeGroupAndProfile(stores)
            changeCustody(stores)
            #expect(stores.peers.peer(bob)?.name == "Bobby")
            #expect(stores.peers.peer(carol) != nil)
            #expect(stores.messages.message("m2") != nil)
            #expect(stores.messages.message("m1") == nil)
            #expect(stores.messages.contains("m1"), "its id is remembered as deleted")
            #expect(stores.conversations.acceptedConversations().contains("another thread"))
            #expect(stores.blocks.blockedNodeIds() == [carol])
            #expect(stores.blocks.isBlocked(deviceTag: "carol's tag"))
            #expect(stores.groups.group(groupId)?.name == "After")
            #expect(stores.ownProfile.load().status == "here")
            #expect(stores.ownProfile.loadIfReadable()?.status == "here")
            #expect(stores.custody.frame("f2", now: 0) != nil)
            #expect(!stores.custody.contains("f1"))
            return nil
        }
        #expect(outcome == .abandoned)
        #expect(contents(stores) == before)
    }

    @Test func everyMemoryStorePutsBackExactlyWhatItHeld() throws {
        let memory = try RepositoryKind.memory.make()
        let blobs = MemoryBlobStore()
        let kept = try #require(BlobHash(String(repeating: "a", count: 64)))
        let dropped = try #require(BlobHash(String(repeating: "b", count: 64)))
        seed(memory)
        blobs.insert(Array("kept".utf8), hash: kept, mime: "image/jpeg", storedAt: 1)
        let before = contents(memory)
        let unit = MemoryTransactor(stores: [blobs])
        let outcome = unit.atomically { () -> Int? in
            blobs.insert(Array("dropped".utf8), hash: dropped, mime: "image/jpeg", storedAt: 2)
            blobs.remove(kept)
            return nil
        }
        #expect(outcome == .abandoned)
        #expect(blobs.allHashes() == [kept])
        #expect(blobs.bytes(of: kept) == Array("kept".utf8))
        let all = memory.transactor.atomically { () -> Int? in
            changePeopleAndMessages(memory)
            changeGroupAndProfile(memory)
            changeCustody(memory)
            return nil
        }
        #expect(all == .abandoned)
        #expect(contents(memory) == before)
    }

    @Test func failingAMemoryUnitOutsideOneFailsNothing() throws {
        let stores = try RepositoryKind.memory.make()
        let unit = try #require(stores.transactor as? MemoryTransactor)
        unit.failCurrentUnit()
        let outcome = unit.atomically { () -> Int? in
            stores.conversations.accept(thread)
            return 1
        }
        #expect(outcome == .committed(1))
        #expect(stores.conversations.acceptedConversations() == [thread])
    }
}

// The fixtures, apart from the suite only to keep its body inside the lint's length.
extension StoreTransactorTests {
    /// What the stores hold, as far as these tests write them.
    private struct Contents: Equatable {
        var peers: [PeerRecord]
        var thread: [MessageRecord]
        var conversations: Set<String>
        var blocked: Set<NodeId>
        var groups: [GroupRecord]
        var ownProfile: OwnProfile
        var custody: [String]
        /// The DM ratchet's rows with Bob, and the group form's rows in the group: both ratchet stores join the unit.
        var ratchet: RatchetPeerRecords
        var groupRatchet: GroupRatchetHoldings
    }

    private var thread: String { Conversations.id(sender: bob, recipient: alice, me: alice) }

    private func contents(_ stores: RepositoryKind.Stores) -> Contents {
        Contents(
            peers: stores.peers.allPeers(),
            thread: stores.messages.messages(in: thread),
            conversations: stores.conversations.acceptedConversations(),
            blocked: stores.blocks.blockedNodeIds(),
            groups: stores.groups.groups(),
            ownProfile: stores.ownProfile.load(),
            custody: stores.custody.liveIds(now: 0).sorted(),
            ratchet: stores.ratchet.records(of: bob),
            groupRatchet: stores.groupRatchet.holdings(of: groupId)
        )
    }

    private func message(_ id: String, sentAt: Int64) -> MessageRecord {
        MessageRecord(id: id, senderId: bob, recipientId: alice, conversationId: thread, body: "hi", sentAt: sentAt)
    }

    private func group(named name: String) -> GroupRecord {
        GroupRecord(
            id: groupId,
            name: name,
            createdBy: alice.string,
            createdAt: 1,
            nameUpdatedAt: 1,
            roster: [GroupMember(nodeId: alice.string), GroupMember(nodeId: bob.string)]
        )
    }

    private func frame(_ id: String) -> CarriedFrame {
        let envelope = RelayEnvelope(type: .chat, id: id, senderId: bob.string, sentAt: 1, recipientId: alice.string, payload: [])
        return CarriedFrame(envelope: envelope, sig: [], signed: envelope.encoded)
    }

    /// What every store held before the unit: one of everything the change replaces or removes.
    private func seed(_ stores: RepositoryKind.Stores) {
        stores.peers.upsert(PeerRecord(nodeId: bob, name: "Bob", status: "", publicKey: "key", updatedAt: 1))
        stores.messages.insertIfAbsent(message("m1", sentAt: 1))
        stores.conversations.accept(thread)
        stores.groups.save(group(named: "Before"))
        stores.ownProfile.save(OwnProfile(name: "Alice", version: 1, publishedAt: 1))
        stores.custody.store(frame("f1"), origin: .relayed, now: 0)
        stores.ratchet.upsertSession(.plain(with: bob, root: 1))
        stores.groupRatchet.insertRecvChain(.plain(mintedAt: 1), in: groupId, from: bob)
    }

    /// The part of a change that pins, stores and accepts: a replacement and an insert in each store it writes.
    private func changePeopleAndMessages(_ stores: RepositoryKind.Stores) {
        stores.peers.upsert(PeerRecord(nodeId: bob, name: "Bobby", status: "", publicKey: "key", updatedAt: 2))
        stores.peers.upsert(PeerRecord(nodeId: carol, name: "Carol", status: "", publicKey: "key", updatedAt: 2))
        stores.messages.insertIfAbsent(message("m2", sentAt: 2))
        stores.messages.deleteMessage("m1", at: 3)
        stores.conversations.accept("another thread")
        stores.blocks.block(carol, deviceTag: "carol's tag")
    }

    /// The part of a change that renames the group and edits our profile.
    private func changeGroupAndProfile(_ stores: RepositoryKind.Stores) {
        stores.groups.save(group(named: "After"))
        stores.ownProfile.save(OwnProfile(name: "Alice", status: "here", version: 2, publishedAt: 2))
    }

    /// The part of a change that carries one frame and drops another, and moves both ratchets: a session replaced, a seed added.
    private func changeCustody(_ stores: RepositoryKind.Stores) {
        stores.custody.store(frame("f2"), origin: .own, now: 0)
        stores.custody.remove("f1")
        stores.ratchet.upsertSession(.plain(with: bob, root: 2))
        stores.groupRatchet.insertRecvChain(.plain(mintedAt: 2), in: groupId, from: bob)
    }

    /// What the stores hold after the seed and `parts` with no unit at all: what a unit that commits them must leave.
    private func withoutAUnit(_ kind: RepositoryKind, _ parts: [(RepositoryKind.Stores) -> Void]) throws -> Contents {
        let stores = try kind.make()
        seed(stores)
        for part in parts {
            part(stores)
        }
        return contents(stores)
    }

    /// In memory nothing refuses ``failingWrite(_:)``, so a double stands in for the group store there, refusing every
    /// save and failing the unit it runs in, as the database's error does.
    private func refuseGroupWritesInMemory(_ kind: RepositoryKind, in stores: inout RepositoryKind.Stores) throws {
        if kind == .memory {
            stores.groups = RefusingGroupStore(held: stores.groups, unit: try #require(stores.transactor as? MemoryTransactor))
        }
    }

    /// A write the database refuses, for the store error a full disk would raise: a roster naming a member twice breaks
    /// `group_members`' primary key.
    private func failingWrite(_ stores: RepositoryKind.Stores) {
        var twice = group(named: "Twice")
        twice.roster.append(GroupMember(nodeId: bob.string))
        stores.groups.save(twice)
    }
}
