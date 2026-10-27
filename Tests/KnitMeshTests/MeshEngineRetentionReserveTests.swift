import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Both sides of a trimmed message request (knit-ios #21, the crypto review's blocking finding): a fork opens 120 request
/// threads with the identities it mints and floods one v1 thread and one ratchet thread past 50. The iPhone's sweep trims
/// them and remembers each trimmed id, so a carrier that re-serves one past the router's ten minutes, the start's replay of
/// custodied ratchet DMs and the 60 s digest exchange bring none of them back, announce nothing, and leave both custodies
/// as they were. Android's bare delete lets each come back as a new request. A fresh DM from the same session still opens.
@Suite struct MeshEngineRetentionReserveTests {
    private let me = TestPeer(seed: 1)
    private let carol = TestPeer(seed: 3)
    private let vic = TestPeer(seed: 10)
    private let sam = TestPeer(seed: 11)
    private var now: Int64 { EngineFixture.start }
    private var sweep: Int64 { MeshConfiguration().sweepMilliseconds }

    /// Carries what each engine writes to the other until both fall quiet, as a live link between them would.
    private func exchange(_ one: EngineFixture, _ other: EngineFixture) {
        var quiet = false
        while !quiet {
            quiet = true
            for (from, to) in [(one, other), (other, one)] {
                let written = from.transport.written.filter { $0.to == nil || $0.to == to.me.nodeId }
                let digests = from.transport.digests.filter { $0.to == to.me.nodeId }
                from.transport.clear()
                for frame in written {
                    quiet = false
                    to.engine.receiveAdmitted(InboundFrame(wire: frame.wire, envelope: frame.envelope, from: from.me.nodeId))
                }
                for digest in digests {
                    quiet = false
                    to.engine.receiveDigest(digest.ids, from: from.me.nodeId)
                }
            }
        }
    }

    /// Moves both clocks on by `milliseconds`, firing what is due on each, then carries what they wrote.
    private func advance(_ milliseconds: Int64, _ iphone: EngineFixture, _ carrier: EngineFixture) {
        iphone.advance(milliseconds)
        carrier.advance(milliseconds)
        exchange(iphone, carrier)
    }

    /// What `fixture`'s ratchet refused, by reason: a re-served DM the exists-gate stops never reaches it, where one that
    /// opened again under a spent key counts as a duplicate.
    private func ratchetDrops(_ fixture: EngineFixture) -> [DropReason: Int] {
        let ratchet: Set<DropReason> = [.ratchetDuplicate, .ratchetNoSession, .ratchetEpochGone, .ratchetAeadFail, .ratchetBadHeader]
        return fixture.engine.dropped.filter { ratchet.contains($0.key) }
    }

    private func liveIds(_ fixture: EngineFixture) -> Set<String> {
        Set(fixture.stores.custody.liveIds(now: fixture.clock.wallMilliseconds()))
    }

    /// 118 one-message threads from `forks`, then 55 v1 DMs from Vic and 55 ratchet DMs from Sam's `android`, every copy
    /// reaching both phones, which have pinned everyone: the frames by id.
    private func flood(
        _ iphone: EngineFixture, _ carrier: EngineFixture, forks: [TestPeer], android: AndroidPeer
    ) throws -> [String: TestFrame] {
        for fixture in [iphone, carrier] {
            for peer in forks + [vic] {
                try fixture.pin(peer)
            }
            try fixture.pin(android)
        }
        iphone.link(carol)
        carrier.link(me)
        exchange(iphone, carrier)
        var frames: [(TestPeer, TestFrame)] = []
        for (index, fork) in forks.enumerated() {
            frames.append((fork, try fork.directMessage("hello", to: me, id: frameIdOf("fork-\(index)"), sentAt: now + Int64(index))))
        }
        for index in 0..<55 {
            let id = frameIdOf("vic-\(index)")
            frames.append((vic, try vic.directMessage("v\(index)", to: me, id: id, sentAt: now + 200 + Int64(index))))
        }
        let prekey = try iphone.ourPrekey()
        for index in 0..<55 {
            let id = frameIdOf("sam-\(index)")
            frames.append((sam, try android.dm("s\(index)", to: me, prekey: prekey, id: id, sentAt: now + 300 + Int64(index))))
        }
        for (sender, frame) in frames {
            carrier.deliver(frame, from: sender)
            iphone.deliver(frame, from: sender)
        }
        return Dictionary(uniqueKeysWithValues: frames.map { ($0.1.envelope.id, $0.1) })
    }

    @Test(arguments: StoreKind.allCases)
    func trimmedRequestsStayGoneThroughAReserveTheDigestAndARestart(kind: StoreKind) throws {
        let directory = scratchDirectory("retention-reserve")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, _) = try kind.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let keychain = KeptSecretStore(me.keys.storedForm)
        let iphone = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain)
        let carrier = EngineFixture(carol, seed: 9)
        let android = try AndroidPeer(sam)
        // Seeds wrap at 256: these stay clear of ours, Carol's, Vic's and Sam's.
        let frames = try flood(iphone, carrier, forks: (0..<118).map { TestPeer(seed: 20 + $0) }, android: android)
        #expect(stores.messages.messages(in: sam.nodeId.string).count == 55, "every ratchet DM opened")
        #expect(stores.messages.conversationIds().count == 120)
        advance(Router.Configuration().jitterWindowMilliseconds, iphone, carrier)
        #expect(liveIds(iphone) == liveIds(carrier))
        let carried = liveIds(iphone)
        _ = iphone.engine.drainEvents()

        advance(sweep, iphone, carrier)
        let trimmed = Set(
            (0..<20).map { frameIdOf("fork-\($0)") } + (0..<5).map { frameIdOf("vic-\($0)") } + (0..<5).map { frameIdOf("sam-\($0)") })
        #expect(stores.messages.messages(in: vic.nodeId.string).count == 50 && stores.messages.messages(in: sam.nodeId.string).count == 50)
        #expect(stores.messages.conversationIds().count == 100, "the 100 most recently active requests are left")
        #expect(trimmed.allSatisfy { stores.messages.message($0) == nil && stores.messages.contains($0) }, "each trimmed id is remembered")
        #expect(stores.messages.deletedAttachments().isEmpty)
        #expect(liveIds(iphone) == carried && liveIds(carrier) == carried, "retention touched no custody")
        let threads = iphone.engine.drainEvents()
        #expect(threads.count == 1 && announced(threads).isEmpty)

        // Past the router's window: the digests run, then a carrier that missed every receipt re-serves the trimmed frames.
        advance(11 * 60_000, iphone, carrier)
        for id in trimmed.sorted() {
            let frame = try #require(frames[id])
            iphone.engine.receiveAdmitted(InboundFrame(wire: frame.wire, envelope: frame.envelope, from: carol.nodeId))
        }
        #expect(ratchetDrops(iphone).isEmpty, "the exists-gate took Sam's, not the ratchet's spent keys")
        #expect(iphone.resetsSent(to: sam).isEmpty, "and nothing counted toward a reset")
        exchange(iphone, carrier)
        #expect(trimmed.allSatisfy { stores.messages.message($0) == nil }, "no trimmed id got its row back")
        #expect(announced(iphone.engine.drainEvents()).isEmpty, "nothing was announced again")
        #expect(liveIds(iphone) == liveIds(carrier), "the custodies still agree")

        // A start opens the custodied ratchet DMs to us that have no row, and none of these.
        let restarted = try EngineFixture.ratcheting(
            me, stores: stores, keychain: keychain, wall: iphone.clock.wallMilliseconds(), seed: 61)
        #expect(trimmed.allSatisfy { stores.messages.message($0) == nil })
        #expect(announced(restarted.engine.drainEvents()).isEmpty)
        #expect(stores.messages.messages(in: sam.nodeId.string).count == 50)
        #expect(ratchetDrops(restarted).isEmpty && restarted.resetsSent(to: sam).isEmpty, "the replay skipped them at the gate")

        let fresh = try android.dm(
            "still here", to: me, prekey: try restarted.ourPrekey(), id: frameIdOf("sam-fresh"), sentAt: restarted.clock.wallMilliseconds())
        restarted.deliver(fresh, from: sam)
        #expect(stores.messages.message(frameIdOf("sam-fresh"))?.body == "still here", "a fresh DM from the same session opens")
        #expect(announced(restarted.engine.drainEvents()).map(\.isRequest) == [true])
    }

    /// The crypto review of batch B: a carrier whose clock runs 2 h behind ours took Vic's DM while it was live, and by its
    /// own clock still holds it after our custody let it go. We trim the row 24 h 30 min after its `sentAt`, past a
    /// window measured on our clock alone, and the carrier's re-serve, long past the router's window, brings nothing back.
    @Test func aCarrierWhoseClockLagsReservesATrimmedRowThatStaysGone() throws {
        let lag: Int64 = 2 * 3_600_000
        let iphone = EngineFixture(me)
        let carrier = EngineFixture(carol, wall: now - lag, seed: 9)
        try iphone.pin(vic)
        try carrier.pin(vic)
        let early = try vic.directMessage("early", to: me, id: frameIdOf("vic-early"), sentAt: now - lag)
        carrier.deliver(early, from: vic)
        iphone.deliver(early, from: vic)
        let ttl = CustodyLimits().ttlMilliseconds
        iphone.advance(ttl + 30 * 60_000 - lag)
        carrier.advance(ttl + 30 * 60_000 - lag)
        for index in 0..<50 {
            let id = frameIdOf("vic-late-\(index)")
            iphone.deliver(try vic.directMessage("late", to: me, id: id, sentAt: iphone.clock.wallMilliseconds() + Int64(index)), from: vic)
        }
        _ = iphone.engine.drainEvents()
        iphone.advance(sweep)
        carrier.advance(sweep)
        #expect(iphone.stores.messages.message(frameIdOf("vic-early")) == nil, "trimmed past the newest 50")
        #expect(!iphone.stores.custody.contains(frameIdOf("vic-early")), "our custody let it go")
        let carried = try #require(
            carrier.stores.custody.liveFrames(now: carrier.clock.wallMilliseconds()).first { $0.envelope.id == frameIdOf("vic-early") },
            "the carrier still holds it by its own clock")
        iphone.engine.receiveAdmitted(InboundFrame(wire: carried.reserved, envelope: carried.envelope, from: carol.nodeId))
        #expect(iphone.stores.messages.message(frameIdOf("vic-early")) == nil, "no row came back")
        #expect(announced(iphone.engine.drainEvents()).isEmpty)
    }

    /// The follow-up reviews of batch B: a count trims a row within one sweep of its arrival, and a carrier whose clock runs
    /// 2 h behind ours refuses the frame as dated ahead until its clock catches up, then holds it to our `sentAt` plus the
    /// TTL plus 2 h. It re-serves an hour past our TTL, a request DM's (24 h) and a room post's (6 h), and nothing comes
    /// back: the tombstone lasts to `sentAt` plus two TTLs.
    @Test(arguments: [false, true])
    func aCarrierWhoseClockLagsReservesARowTrimmedEarlyThatStaysGone(inRoom: Bool) throws {
        let lag: Int64 = 2 * 3_600_000
        let limits = CustodyLimits()
        let ttl = inRoom ? limits.roomChatTTLMilliseconds : limits.ttlMilliseconds
        let iphone = EngineFixture(me)
        let carrier = EngineFixture(carol, wall: now - lag, seed: 9)
        try iphone.pin(vic)
        try carrier.pin(vic)
        func frame(_ id: String, sentAt: Int64) throws -> TestFrame {
            inRoom
                ? try vic.roomPost("post", id: frameIdOf(id), sentAt: sentAt)
                : try vic.directMessage("dm", to: me, id: frameIdOf(id), sentAt: sentAt)
        }
        let early = try frame("vic-early", sentAt: now)
        iphone.deliver(early, from: vic)
        // A stranger's room posts past their newest 200, or a request past its newest 50, push it out at the next sweep.
        for index in 0..<(inRoom ? MessageRetention.roomMaxPerStranger : MessageRetention.maxPerPendingThread) {
            iphone.deliver(try frame("vic-\(index)", sentAt: now + 1 + Int64(index)), from: vic)
        }
        _ = iphone.engine.drainEvents()
        iphone.advance(sweep)
        #expect(iphone.stores.messages.message(frameIdOf("vic-early")) == nil, "trimmed within a sweep of arriving")

        carrier.advance(lag)
        carrier.deliver(early, from: vic)
        carrier.advance(ttl + 1 * 3_600_000 - lag)
        iphone.advance(ttl + 1 * 3_600_000 - sweep)
        #expect(!iphone.stores.custody.contains(frameIdOf("vic-early")), "our custody let it go")
        let carried = try #require(
            carrier.stores.custody.liveFrames(now: carrier.clock.wallMilliseconds()).first { $0.envelope.id == frameIdOf("vic-early") },
            "the carrier still holds it by its own clock")
        iphone.engine.receiveAdmitted(InboundFrame(wire: carried.reserved, envelope: carried.envelope, from: carol.nodeId))
        #expect(iphone.stores.messages.message(frameIdOf("vic-early")) == nil, "no row came back")
        #expect(announced(iphone.engine.drainEvents()).isEmpty)
    }
}
