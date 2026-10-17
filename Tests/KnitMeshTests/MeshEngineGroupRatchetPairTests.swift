import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The group form received in the mesh against custody and the store unit (ADR 2026-10.5sk9, phase P6a2): the trials the
/// P6a1 reviews owe, as two engines over the database with the switch on, an iPhone and a carrier exchanging digests in an
/// ``EngineLab``, with an Android phone authoring the group form (``GroupFormAuthor``). The restarts are
/// ``MeshEngineGroupRatchetRestartTests``, and the iPhone's own sends `GroupSendPairTests` (phase P6b).
@Suite struct MeshEngineGroupRatchetPairTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)

    private var now: Int64 { EngineFixture.start }
    private static let hour: Int64 = 3_600_000
    private var jitter: Int64 { Router.Configuration().jitterWindowMilliseconds + 1 }

    /// The iPhone over the database with the switch on, a carrier in memory, both linked, and Alice pinned on both.
    private func lab(_ stores: MeshStores) throws -> (EngineLab, AndroidPeer) {
        let android = try AndroidPeer(alice)
        let iphone = try EngineFixture.ratcheting(me, stores: stores)
        let carrier = EngineFixture(carol, seed: 9)
        try iphone.pin(android)
        try carrier.pin(android)
        let lab = EngineLab([iphone, carrier])
        lab.link(0, 1)
        lab.advance(jitter)
        return (lab, android)
    }

    /// Alice's frame handed to the iPhone, relayed to the carrier once the router's jitter runs out.
    private func arrive(_ frame: TestFrame, in lab: EngineLab) {
        lab[0].deliver(frame, from: alice)
        lab.advance(jitter)
    }

    /// The frames of `id` the carrier wrote, which would be its custody serving that frame back.
    private func served(_ id: String, in lab: EngineLab) -> Int {
        lab[1].transport.written.count { ExactKey($0.envelope.id) == ExactKey(id) }
    }

    /// The frames of `id` the iPhone wrote: its router's one relay, and any more would be a replay serving it again.
    private func relayed(_ id: String, in lab: EngineLab) -> Int {
        lab[0].transport.written.count { ExactKey($0.envelope.id) == ExactKey(id) }
    }

    /// The chats of our own the iPhone wrote after its first `count` writes, as Alice reads them: a replay's own frames
    /// would show here.
    private func ourChats(in lab: EngineLab, after count: Int, android: AndroidPeer) -> [MessageContent?] {
        lab[0].transport.written.dropFirst(count).filter { written in
            written.envelope.type == .chat && ExactKey(written.envelope.senderId) == ExactKey(me.nodeId.string)
        }.map { android.peek($0, from: me) }
    }

    /// Both nodes' digests at the next re-offer, and whatever they serve each other.
    private func exchangeDigests(_ lab: EngineLab) {
        lab.advance(MeshConfiguration().reofferMilliseconds)
    }

    @Test func aGroupFrameBeforeItsSeedIsCustodiedAtOnceAndTheInstantReplayDeliversItWithNoReServe() throws {
        let directory = scratchDirectory("group-before-seed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, _) = try StoreKind.sql.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let (lab, android) = try lab(stores)
        let group = roster([me, alice], createdBy: alice)
        let author = GroupFormAuthor(android, in: group.id)
        arrive(try author.frame(group, id: "g-early", body: "before the seed", sentAt: now), in: lab)
        #expect(lab[0].engine.dropped[.groupRatchetNoKey] == 1)
        #expect(lab[0].stores.custody.contains("g-early"), "custodied at once")
        #expect(lab[1].stores.custody.contains("g-early"), "and relayed to the carrier")
        #expect(relayed("g-early", in: lab) == 1)
        let before = lab[0].transport.written.count
        arrive(try author.seedDm(to: me, prekey: try lab[0].ourPrekey(), id: "seed-1", sentAt: now + 1), in: lab)
        #expect(lab[0].stores.messages.message("g-early")?.body == "before the seed", "the instant replay opened our own copy")
        #expect(served("g-early", in: lab) == 0, "nobody served it again")
        #expect(relayed("g-early", in: lab) == 1, "and the replay sent no copy of its own")
        // The seed was Alice's first DM, so its open answers her init with our profile, then acknowledges the seed.
        let answers = [MessageContent.Control.profile, MessageContent.Control.groupKeyAck]
        #expect(ourChats(in: lab, after: before, android: android).map { $0?.ctl } == answers, "nothing of the replay's own")
        exchangeDigests(lab)
        #expect(served("g-early", in: lab) == 0)
        #expect(relayed("g-early", in: lab) == 1)
        #expect(Set(lab.liveIds(0)) == Set(lab.liveIds(1)), "the same ids in both custodies after a digest")
        #expect(lab[0].stores.groupRatchet.holdings(of: group.id).recvChains[alice.nodeId]?.count == 1)
    }

    @Test func aGroupOpenWhoseRowIsRefusedDeliversNothingAndTheHourlyReplayDeliversIt() throws {
        let directory = scratchDirectory("group-row-refused")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try StoreKind.sql.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let (lab, android) = try lab(stores)
        let group = lab[0].holdGroup(with: [alice])
        let author = GroupFormAuthor(android, in: group.id)
        arrive(try author.seedDm(to: me, prekey: try lab[0].ourPrekey(), id: "seed-1", sentAt: now), in: lab)
        _ = lab[0].engine.drainEvents()
        refusing.refusesRows = true
        arrive(try author.frame(group, id: "g-1", body: "kept", sentAt: now + 1), in: lab)
        refusing.refusesRows = false
        #expect(lab[0].engine.dropped[.storeRefused] == 1)
        #expect(
            lab[0].stores.messages.message("g-1") == nil && receivedRecords(in: lab[0].engine.drainEvents()).isEmpty, "nothing delivered")
        #expect(lab[0].stores.custody.contains("g-1"), "the frame stays in custody")
        #expect(lab[0].recvChains(group.id, from: alice).first?.next == 0, "the chain rolled back with the row")
        exchangeDigests(lab)
        #expect(lab[0].stores.messages.message("g-1") == nil, "no neighbour serves it again: our digest lists it")
        let relays = relayed("g-1", in: lab)
        let before = lab[0].transport.written.count
        lab.advance(Self.hour)
        #expect(lab[0].stores.messages.message("g-1")?.body == "kept", "the hourly replay delivered it")
        #expect(receivedRecords(in: lab[0].engine.drainEvents()).map(\.id) == ["g-1"])
        #expect(relayed("g-1", in: lab) == relays, "the replay sent no copy of its own")
        let since = ourChats(in: lab, after: before, android: android)
        #expect(since.allSatisfy { $0?.ctl == MessageContent.Control.receipt }, "a tick at most")
        exchangeDigests(lab)
        #expect(Set(lab.liveIds(0)) == Set(lab.liveIds(1)), "live ids end equal")
    }

    @Test func theInMemoryUnitRestoresTheGroupStoreWhenItFails() throws {
        let stores = MeshStores.inMemory()
        let transactor = try #require(stores.transactor as? MemoryTransactor)
        let chain = GroupRecvChainRecord(epoch: 1, mintedAt: 5, chainKey: [UInt8](repeating: 7, count: 32), next: 0, lastUsedAt: 5)
        let unit = transactor.atomically { () -> Int? in
            stores.groupRatchet.insertRecvChain(chain, in: "g-1", from: alice.nodeId)
            stores.groupRatchet.markKeySent("g-1", to: alice.nodeId, epoch: 1, at: 5)
            transactor.failCurrentUnit()
            return 1
        }
        #expect(unit == .failed)
        #expect(stores.groupRatchet.holdings(of: "g-1") == .empty, "the group store is undone with the rest")
        let kept = transactor.atomically { () -> Int? in
            stores.groupRatchet.insertRecvChain(chain, in: "g-1", from: alice.nodeId)
            return 1
        }
        #expect(kept == .committed(1))
        #expect(stores.groupRatchet.recvChains("g-1", from: alice.nodeId, epoch: 1) == [chain])
    }

    /// The blobs review's trial (d): a frame id that starts with U+FEFF, beside the frame it would shadow, over the database.
    @Test func aFrameIdLedByAByteOrderMarkIsListedWholeIsNotServedBackAndHidesNothing() throws {
        let directory = scratchDirectory("bom-frame")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, _) = try StoreKind.sql.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let fixture = try EngineFixture.ratcheting(me, stores: stores)
        try fixture.pin(carol)
        let marked = "\u{FEFF}x-frame"
        fixture.deliver(try carol.roomPost("marked", id: marked, sentAt: now), from: carol)
        fixture.deliver(try carol.roomPost("plain", id: "x-frame", sentAt: now), from: carol)
        fixture.transport.clear()
        fixture.link(carol)
        let digest = try #require(fixture.transport.digests.last { $0.to == carol.nodeId }).ids
        let listed = digest.filter { $0.hasSuffix("x-frame") }.map { Array($0.utf8) }
        #expect(Set(listed) == [[0xEF, 0xBB, 0xBF] + Array("x-frame".utf8), Array("x-frame".utf8)], "listed as itself, beside the frame")
        fixture.transport.clear()
        fixture.engine.receiveDigest(digest, from: carol.nodeId)
        #expect(fixture.transport.written.isEmpty, "a digest that lists it whole gets nothing back")
        fixture.engine.receiveDigest(digest.filter { ExactKey($0) != ExactKey("x-frame") }, from: carol.nodeId)
        #expect(fixture.transport.written.map(\.envelope.id) == ["x-frame"], "the marked id hides nothing of the real one")
    }

    /// The crypto re-review's trial: a wiped sender's two eras, both in custody, at a receiver that adopted the old seed first,
    /// re-served across the indices they share. Indices 5 are messages, which a re-serve meets at the exists-gate; indices 3
    /// are reactions, which have no row, so a re-serve reaches the open and drops as `DUPLICATE`.
    @Test(arguments: [["old5", "new5", "new3", "old3"], ["old3", "new3", "new5", "old5"]])
    func aWipedSendersTwoErasAreEachDeliveredOnceInEitherOrder(order: [String]) throws {
        let directory = scratchDirectory("two-eras")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, _) = try StoreKind.sql.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let fixture = try EngineFixture.ratcheting(me, stores: stores)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        let group = fixture.holdGroup(with: [alice])
        let author = GroupFormAuthor(android, in: group.id, mintedAt: now - 60_000)
        let prekey = try fixture.ourPrekey()
        fixture.deliver(try author.seedDm(to: me, prekey: prekey, id: "seed-old", sentAt: now), from: android)
        var frames: [String: TestFrame] = [:]
        func era(_ name: String) throws {
            for index in 0...5 {
                let id = "\(name)\(index)"
                frames[id] =
                    index == 3
                    ? try author.reaction(group, id: id, sentAt: now + 1, on: "target-\(name)", emoji: "\u{1F525}")
                    : try author.frame(group, id: id, body: "\(name) \(index)", sentAt: now + 1)
            }
        }
        try era("old")
        author.wipeAndRemint(at: now)
        fixture.deliver(try author.seedDm(to: me, prekey: prekey, id: "seed-new", sentAt: now + 2), from: android)
        try era("new")
        #expect(fixture.recvChains(group.id, from: alice).count == 2, "both eras adopted, the old first")
        _ = fixture.engine.drainEvents()
        for id in order {
            fixture.deliver(try #require(frames[id]), from: alice)
        }
        #expect(fixture.stores.messages.message("old5")?.body == "old 5" && fixture.stores.messages.message("new5")?.body == "new 5")
        #expect(fixture.stores.messages.reaction(on: "target-old", by: alice.nodeId) != nil)
        #expect(fixture.stores.messages.reaction(on: "target-new", by: alice.nodeId) != nil)
        #expect(Set(receivedRecords(in: fixture.engine.drainEvents()).map(\.id)) == ["old5", "new5"], "each delivered once")
        fixture.advance(SeenSet.defaultWindowMilliseconds + 1)
        for id in order {
            fixture.deliver(try #require(frames[id]), from: alice)
        }
        #expect(receivedRecords(in: fixture.engine.drainEvents()).isEmpty, "a re-serve delivers nothing again")
        #expect(fixture.engine.dropped[.groupRatchetDuplicate] == 2, "each re-served reaction is a duplicate")
        #expect(fixture.engine.dropped[.groupRatchetNoKey] == nil && fixture.engine.dropped[.groupRatchetAeadFail] == nil)
        #expect(!fixture.controls(to: android).contains { $0.ctl == MessageContent.Control.groupKeyRequest }, "no key request")
    }

    /// The unit (P4a): a seed DM whose open's unit fails adopts nothing, moves no floor and sends no ack; the copy kept opens
    /// again at the next sweep, and only then is the seed adopted, the floor moved and the ack sent, over both store kinds.
    @Test(arguments: StoreKind.allCases)
    func aSeedWhoseDmUnitFailsAdoptsNothingAndMovesNoFloorUntilItsReplayCommits(kind: StoreKind) throws {
        let directory = scratchDirectory("seed-unit-fails")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingOpens(blobs: directory, failures: ReportedFailures().record)
        let fixture = try EngineFixture.ratcheting(me, stores: stores)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        let group = fixture.holdGroup(with: [alice])
        let author = GroupFormAuthor(android, in: group.id)
        fixture.transport.clear()
        refusing.refusesWrites = true
        fixture.deliver(try author.seedDm(to: me, prekey: try fixture.ourPrekey(), id: "seed-1", sentAt: now), from: android)
        refusing.refusesWrites = false
        #expect(fixture.engine.dropped[.storeRefused] == 1)
        #expect(fixture.recvChains(group.id, from: alice).isEmpty, "the adoption went with the unit")
        #expect(fixture.engine.groupRatchet.floors(in: group.id, for: alice.nodeId, now: now).adoptions == 0, "no floor moved")
        #expect(fixture.engine.groupCounts == RatchetGroupCounts() && fixture.transport.written(.chat).isEmpty, "no ack, nothing sent")
        fixture.advance(MeshConfiguration().sweepMilliseconds)
        #expect(fixture.recvChains(group.id, from: alice).count == 1, "adopted from the copy kept")
        #expect(fixture.engine.groupRatchet.floors(in: group.id, for: alice.nodeId, now: now).adoptions == 1, "settled once it committed")
        #expect(fixture.controls(to: android).contains { $0.ctl == MessageContent.Control.groupKeyAck })
    }

    /// The replays' exists-gate: a frame whose row read fails inside the replay's own unit is skipped until the next replay,
    /// never opened on the store's fallback, which for a delivered frame would spend nothing and drop as a duplicate.
    @Test func aCustodyReplayWhoseRowReadFailsSkipsTheFrame() throws {
        let directory = scratchDirectory("replay-read-fails")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try StoreKind.sql.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let fixture = try EngineFixture.ratcheting(me, stores: stores)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        let group = fixture.holdGroup(with: [alice])
        let author = GroupFormAuthor(android, in: group.id)
        fixture.deliver(try author.seedDm(to: me, prekey: try fixture.ourPrekey(), id: "seed-1", sentAt: now), from: android)
        fixture.deliver(try author.frame(group, id: "g-1", body: "delivered", sentAt: now), from: alice)
        #expect(fixture.stores.messages.message("g-1") != nil)
        refusing.failsReads = true
        fixture.advance(Self.hour)
        refusing.failsReads = false
        #expect(fixture.log.all.contains { $0.contains("mesh custody replay of g-1 skipped: a store failed") })
        #expect(fixture.engine.dropped[.groupRatchetDuplicate] == nil, "never opened on the fallback")
        fixture.advance(Self.hour)
        #expect(fixture.engine.dropped[.groupRatchetDuplicate] == nil, "a row that reads lets it be")
    }
}
