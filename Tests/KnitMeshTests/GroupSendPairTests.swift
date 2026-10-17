import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The group form sent in the mesh against the database, custody and the store unit (ADR 2026-10.5sk9, phase P6b): an iPhone
/// author over SQL with the switch on, and as its receivers an iPhone over SQL on P6a2's path and an Android member's own
/// session layers (``GroupFormReader``): the first send, a frame that outruns its seed, a member that missed its seed and
/// asks, a send unit that fails and the heal's retry, and the rejoin rekey's floor.
@Suite struct GroupSendPairTests {
    private let me = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 5)
    private let alice = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private var now: Int64 { EngineFixture.start }
    private var hop: Int64 { Router.Configuration().jitterWindowMilliseconds + 1 }

    /// The two iPhones, each over its own database, linked and acquainted, with Alice, an Android member, pinned by the
    /// author. `holding` holds what the author sends Bob.
    private func pair(_ directory: URL, holding: Bool = false) throws -> (EngineLab, GroupFormReader) {
        let (authorStores, _) = try StoreKind.sql.storesRefusingRows(
            blobs: directory.appending(path: "a"), failures: ReportedFailures().record)
        let (bobStores, _) = try StoreKind.sql.storesRefusingRows(
            blobs: directory.appending(path: "b"), failures: ReportedFailures().record)
        let lab = EngineLab([
            try EngineFixture.ratcheting(me, stores: authorStores, seed: 51),
            try EngineFixture.ratcheting(bob, stores: bobStores, seed: 52),
        ])
        lab.link(0, 1)
        lab.advance(hop)
        let reader = GroupFormReader(try AndroidPeer(alice))
        try lab[0].pin(reader.android)
        if holding {
            lab.hold(from: 0, to: 1)
        }
        return (lab, reader)
    }

    private func isGroupFrame(_ item: EngineLab.Carried) -> Bool {
        guard case .frame(let written) = item else {
            return false
        }
        return written.envelope.group != nil
    }

    @Test func theFirstSendMintsAndDistributesAndEveryMemberOpensItAfterItsSeed() throws {
        let directory = scratchDirectory("group-send-first")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (lab, reader) = try pair(directory)
        let group = try #require(lab[0].engine.createGroup(with: [bob.nodeId, alice.nodeId])).id
        let message = try #require(lab[0].engine.sendGroupMessage("hello", to: group))
        lab.advance(hop)
        lab.advance(hop)
        #expect(lab[1].stores.messages.message(message.id)?.body == "hello", "Bob opens it after the seed its roster pinned")
        #expect(lab[1].stores.groups.group(group) != nil && lab[1].engine.dropped[.groupRatchetNoKey] == nil)
        #expect(lab[0].engine.groupCounts == RatchetGroupCounts(groupSealedRatchet: 1, groupSeedsSent: 2))
        try reader.receive(try #require(lab[0].chats(to: alice).first), from: me)
        #expect(reader.body(of: try #require(lab[0].groupFrames(in: group).first), from: me) == "hello", "and so does Android")
        #expect(lab[0].stores.groupRatchet.keySend(group, member: bob.nodeId)?.ackedEpoch == 1, "Bob's ack moved the outbox")
        #expect(lab[0].stores.groupRatchet.keySend(group, member: alice.nodeId)?.ackedEpoch == 0, "Alice's ack is still to come")
        lab.advance(MeshConfiguration().reofferMilliseconds)
        lab.advance(hop)
        lab.advance(MeshConfiguration().reofferMilliseconds)
        #expect(Set(lab.liveIds(0)) == Set(lab.liveIds(1)), "the same ids in both custodies")
    }

    @Test func aFrameThatOutrunsItsSeedOpensByTheInstantReplay() throws {
        let directory = scratchDirectory("group-send-outrun")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (lab, _) = try pair(directory, holding: true)
        let group = try #require(lab[0].engine.createGroup(with: [bob.nodeId, alice.nodeId])).id
        let message = try #require(lab[0].engine.sendGroupMessage("before its seed", to: group))
        lab.release(from: 0, to: 1) { $0.filter(isGroupFrame) + $0.filter { !isGroupFrame($0) } }
        #expect(lab[1].engine.dropped[.groupRatchetNoKey] == 1, "keyless when it came")
        #expect(lab[1].stores.messages.message(message.id)?.body == "before its seed", "opened from Bob's own custody")
    }

    /// Bob never gets the seed: three keyless frames have him ask, and our answer, the current seed, opens all three.
    @Test func aMemberThatMissedTheSeedAsksAndOurAnswerOpensEverything() throws {
        let directory = scratchDirectory("group-send-request")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (lab, _) = try pair(directory)
        _ = try #require(lab[0].engine.sendDirectMessage("hi", to: bob.nodeId))
        lab.advance(hop)
        lab.hold(from: 0, to: 1)
        let group = try #require(lab[0].engine.createGroup(with: [bob.nodeId, alice.nodeId])).id
        let ids = try (1...3).map { try #require(lab[0].engine.sendGroupMessage("message \($0)", to: group)).id }
        // The seed is lost on the link: only the group frames reach Bob.
        lab.release(from: 0, to: 1) { $0.filter(isGroupFrame) }
        lab.advance(hop)
        lab.advance(hop)
        #expect(lab[1].engine.groupCounts.groupKeyRequestsSent == 1, "the three ask once")
        #expect(lab[0].engine.groupCounts.groupSeedsSent == 3, "the mint's two seeds, then the answer")
        #expect(ids.map { lab[1].stores.messages.message($0)?.body } == ["message 1", "message 2", "message 3"])
        #expect(lab[0].stores.groupRatchet.sendChains(group).map(\.epoch) == [1], "the answer never advanced the epoch")
    }

    @Test(arguments: StoreKind.allCases)
    func aSendUnitThatFailsSendsNothingAndTheHealRetriesIt(kind: StoreKind) throws {
        let directory = scratchDirectory("group-send-fails")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingOpens(blobs: directory, failures: ReportedFailures().record)
        let fixture = try EngineFixture.ratcheting(me, stores: stores)
        let reader = GroupFormReader(try AndroidPeer(alice))
        try fixture.pin(reader.android)
        let group = fixture.holdGroup(with: [alice])
        fixture.transport.clear()
        func ours() -> Set<String> {
            Set(fixture.stores.custody.liveIds(now: fixture.clock.wallMilliseconds()))
        }
        func written() -> Set<String> {
            Set(fixture.transport.written(.chat).map(\.envelope.id))
        }
        let before = ours()
        refusing.refusesWrites = true
        let message = try #require(fixture.engine.sendGroupMessage("not yet", to: group.id))
        refusing.refusesWrites = false
        #expect(message.pendingKey && fixture.stores.messages.message(message.id)?.pendingKey == true, "the row waits")
        #expect(fixture.transport.written(.chat).isEmpty, "nothing on the air")
        #expect(fixture.stores.groupRatchet.holdings(of: group.id) == .empty, "the mint undone")
        #expect(ours() == before && fixture.ratchetRecords(of: alice).session == nil, "no custody row, the seed's included")
        fixture.advance(MeshConfiguration().healMilliseconds)
        #expect(fixture.stores.messages.message(message.id)?.pendingKey == false, "the heal sealed it")
        let frame = try #require(fixture.groupFrames(in: group.id).first)
        try reader.receive(try #require(fixture.chats(to: alice).first), from: me)
        #expect(reader.body(of: frame, from: me) == "not yet" && fixture.groupFrames(in: group.id).count == 1, "sealed once, signed once")
        #expect(ours().subtracting(before) == written() && written().count == 2, "custody holds what went: the seed and the frame")
        // Alice linked and never acknowledging: the first distribution stamped no floor, so the link-up sends the seed once
        // more, and the floor then holds every re-offer for 15 minutes; custody grows by exactly what went.
        fixture.link(alice)
        for _ in 0..<14 {
            fixture.advance(MeshConfiguration().reofferMilliseconds)
        }
        #expect(fixture.chats(to: alice).count == 2 && fixture.groupFrames(in: group.id).count == 1)
        #expect(ours().subtracting(before) == written() && written().count == 3)
    }

    /// The rejoin rekey and its floor (`recordRejoin(rekey:)`, `rejoinRekeyDue`, `InboundPipeline.kt:2166`, `:2311-2321`):
    /// Alice leaves and comes back by her own frame; the first rejoin retires our chain, one inside the hour does not, and one
    /// past it does again. A departure retires it always.
    @Test func aRejoinRekeysOncePerHourAndADepartureAlways() throws {
        let directory = scratchDirectory("group-rejoin")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, _) = try StoreKind.sql.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let fixture = try EngineFixture.ratcheting(me, stores: stores)
        try fixture.pin(try AndroidPeer(alice))
        try fixture.pin(try AndroidPeer(carol))
        let info = fixture.holdGroup(with: [alice, carol])
        var clock = now
        func epochs() -> [Int] { fixture.stores.groupRatchet.sendChains(info.id).map(\.epoch) }
        func cycle(_ label: String) throws {
            _ = try #require(fixture.engine.sendGroupMessage(label, to: info.id))
            clock += 10
            fixture.deliver(try alice.groupLeave(info.id, id: "leave-\(label)", sentAt: clock), from: alice)
            #expect(epochs().isEmpty, "\(label): the departure retired our chain")
            _ = try #require(fixture.engine.sendGroupMessage("\(label) without alice", to: info.id))
            clock += 10
            fixture.deliver(try alice.groupUpdate(info, id: "back-\(label)", sentAt: clock), from: alice)
            #expect(fixture.roster(of: info).departed.isEmpty, "\(label): she is back")
        }
        try cycle("first")
        #expect(epochs().isEmpty, "the first rejoin retired the chain minted while she was out")
        try cycle("inside the hour")
        #expect(!epochs().isEmpty, "a rejoin inside the hour keeps it")
        let kept = epochs()
        fixture.advance(GroupRatchetOutbound.rejoinRekeyMilliseconds)
        clock = fixture.clock.wallMilliseconds()
        try cycle("past the hour")
        #expect(epochs().isEmpty, "past the hour it retires again")
        _ = try #require(fixture.engine.sendGroupMessage("after", to: info.id))
        #expect((epochs().first ?? 0) > (kept.first ?? .max), "the next mint numbers past every retired epoch")
    }
}
