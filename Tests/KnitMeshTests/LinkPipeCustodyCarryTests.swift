import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Paced answers, the carry ledger and the re-offer back-off played on both sides (the `custody-carry-policy` contract,
/// §1 to §7): two engines and their link managers joined by a ``LinkPipe``. `LinkPipe` models no byte rate, and each pump
/// carries every frame a round released at once, so each test reads the rounds from when they crossed.
@Suite struct LinkPipeCustodyCarryTests {
    static let senders = (0..<5).map { TestPeer(seed: 500 + $0) }
    private static let neighbour = TestPeer(seed: 900)

    /// Pins every key in `peers` on `node`, as a node that met them before would hold them.
    static func pin(_ peers: [TestPeer], on node: PipeNode) {
        for peer in peers {
            node.stores.peers.upsert(
                PeerRecord(nodeId: peer.nodeId, name: "", status: "", publicKey: peer.keys.bundle.encoded, updatedAt: 1))
        }
    }

    /// Hands `node` each of `frames` as a neighbour's flood that is not linked: verified and carried, with no source.
    static func seed(_ node: PipeNode, with frames: [TestFrame]) {
        for frame in frames {
            node.engine.receive(InboundFrame(wire: frame.wire, envelope: frame.envelope, from: neighbour.nodeId))
        }
    }

    /// Lets the seeds' relays fall due while nobody is linked, so only the rounds carry them.
    static func settle(_ lab: PipeLab) {
        lab.run(step: 100, limit: 1000) { false }
    }

    /// `count` DMs from the senders in turn to `recipient`, `body` bytes each, sent `sentAt` onward a millisecond apart.
    static func dms(_ count: Int, to recipient: TestPeer, label: String, sentAt: Int64, body: Int = 400) throws -> [TestFrame] {
        try (0..<count).map { index in
            try senders[index % senders.count].directMessage(
                String(repeating: "d", count: body), to: recipient, id: frameIdOf("\(label)-\(index)"), sentAt: sentAt + Int64(index))
        }
    }

    /// The frames `from` released to the other side, by when they crossed: one group per round.
    private static func rounds(on pipe: LinkPipe, from node: PipeNode, ids: Set<String>) -> [(at: Int64, frames: [LinkPipe.Frame])] {
        let served = pipe.frames.filter { $0.from == node.nodeId && ids.contains($0.id) }
        return Dictionary(grouping: served, by: \.at).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// The air's rate in the tests that model a draining link: 8 KiB a second, a slow Bluetooth link.
    static let airRate = 8192

    // MARK: Rounds as the link drains

    @Test func roundsGoAsTheLinkDrainsAndNeverStackPastTwoRounds() throws {
        let lab = PipeLab()
        let wall = lab.clock.wallMilliseconds()
        let holder = lab.node(1)
        let newcomer = lab.node(2)
        for node in [holder, newcomer] {
            Self.pin(Self.senders, on: node)
        }
        let frames = try Self.dms(200, to: TestPeer(seed: 999), label: "pace", sentAt: wall - 10_000)
        Self.seed(holder, with: frames)
        let ids = Set(frames.map(\.envelope.id))
        Self.settle(lab)
        let pipe = lab.link(holder, newcomer)
        // Four times the old 2 s pace's 8 KiB a second, so a clock pacing the rounds would show.
        let rate = 4 * Self.airRate
        pipe.bytesPerSecond = rate
        var most = 0
        let converged = lab.run(step: 100, limit: 120_000) {
            most = max(most, pipe.undelivered(from: holder))
            return ids.allSatisfy { newcomer.stores.custody.contains($0) }
        }
        #expect(converged)
        let rounds = Self.rounds(on: pipe, from: holder, ids: ids)
        let largest = rounds.flatMap(\.frames).map(\.bytes).max() ?? 0
        #expect(holder.engine.custodyRoundCounts.custodyRoundsCut > 4, "several rounds")
        #expect(most < 2 * CustodySync.roundBytes + largest, "\(most) bytes unwritten at most")
        // The link set the pace: about the air's rate, and far faster than a 2 s clock's 16 KiB a round would allow.
        let span = (rounds.last?.at ?? 0) - (rounds.first?.at ?? 0)
        let bytes = rounds.flatMap(\.frames).reduce(0) { $0 + $1.bytes }
        #expect(span <= Int64(bytes) * 1000 / Int64(rate) + 1000, "\(bytes) bytes over \(span) ms")
        #expect(span < Int64(bytes) * 2000 / Int64(CustodySync.roundBytes) / 2, "\(bytes) bytes over \(span) ms")
        // Every frame crossed once.
        let crossed = rounds.flatMap(\.frames).map(\.id)
        #expect(crossed.count == Set(crossed).count)
    }

    // MARK: A cut mid-answer

    @Test func aCutLosesUnderTwoRoundsAndCreditsNothingForTheRoundInFlight() throws {
        let lab = PipeLab()
        let wall = lab.clock.wallMilliseconds()
        let holder = lab.node(1)
        let newcomer = lab.node(2)
        for node in [holder, newcomer] {
            Self.pin(Self.senders, on: node)
        }
        let frames = try Self.dms(200, to: TestPeer(seed: 999), label: "cut", sentAt: wall - 10_000)
        Self.seed(holder, with: frames)
        let ids = Set(frames.map(\.envelope.id))
        Self.settle(lab)
        let pipe = lab.link(holder, newcomer)
        pipe.bytesPerSecond = Self.airRate
        lab.run(step: 100, limit: 8900) { false }
        let answer = try #require(holder.engine.custodyAnswers.answer(for: newcomer.nodeId))
        pipe.cut()
        let crossed = Set(pipe.frames.filter { $0.from == holder.nodeId && ids.contains($0.id) }.map(\.id))
        let released = Set(answer.uncredited.union(answer.released.keys).compactMap { key in ids.first { ExactKey($0) == key } })
        let lost = released.subtracting(crossed)
        #expect(crossed.isSubset(of: released))
        #expect(!lost.isEmpty, "a round was in flight")
        let lostBytes = frames.filter { lost.contains($0.envelope.id) }.reduce(0) { $0 + $1.wire.encoded.count }
        let largest = frames.map(\.wire.encoded.count).max() ?? 0
        #expect(lostBytes < 2 * CustodySync.roundBytes + largest, "under two rounds lost: \(lostBytes) bytes")
        // The last round cut is credited at a look that finds the link drained after it, which the cut came before: its
        // releases are still uncredited in the answer.
        let lastRound = Set(answer.uncredited.compactMap { key in ids.first { ExactKey($0) == key } })
        #expect(!lastRound.isEmpty && lastRound.isSubset(of: lost))
        #expect(lastRound.allSatisfy { !holder.engine.custody.ledger.holders(of: $0).contains(newcomer.nodeId) }, "no credit for it")
        let handed = crossed.filter { holder.engine.custody.ledger.holders(of: $0).contains(newcomer.nodeId) }
        #expect(!handed.isEmpty, "the rounds that crossed in time were credited")
        #expect(holder.engine.custodyRoundCounts.custodyAnswersCutShort == 1)
        // After a relink the lost round crosses again: its memo went with the link.
        let again = lab.link(holder, newcomer)
        lab.run(step: 100, limit: 120_000) { lost.allSatisfy { newcomer.stores.custody.contains($0) } }
        #expect(lost.isSubset(of: Set(again.frames.filter { $0.from == holder.nodeId }.map(\.id))))
    }

    // MARK: Two full stores

    @Test func twoFullStoresServeEachOthersMailInTheFirstRounds() throws {
        // Full: ten DMs, a hundred others, its own profile and room for the other's, which the link-up pushes.
        let limits = CustodyLimits(maxFrames: 112)
        let lab = PipeLab()
        let wall = lab.clock.wallMilliseconds()
        let first = lab.node(1, custodyLimits: limits)
        let second = lab.node(2, custodyLimits: limits)
        for node in [first, second] {
            Self.pin(Self.senders, on: node)
        }
        // Each holds ten DMs for the other, older than the hundred of others' mail it carries besides, received first.
        let forSecond = try Self.dms(10, to: second.peer, label: "for-second", sentAt: wall - 60_000)
        let forFirst = try Self.dms(10, to: first.peer, label: "for-first", sentAt: wall - 60_000)
        Self.seed(first, with: forSecond + (try Self.dms(100, to: TestPeer(seed: 998), label: "a", sentAt: wall - 30_000)))
        Self.seed(second, with: forFirst + (try Self.dms(100, to: TestPeer(seed: 997), label: "b", sentAt: wall - 30_000)))
        #expect(first.stores.custody.liveIds(now: wall).count == limits.maxFrames - 1)
        Self.settle(lab)
        let pipe = lab.link(first, second)
        pipe.bytesPerSecond = Self.airRate
        // Two rounds' worth of the link's time.
        lab.run(step: 100, limit: Int64(2 * CustodySync.roundBytes) * 1000 / Int64(Self.airRate)) { false }
        let fromFirst = Set(pipe.frames.filter { $0.from == first.nodeId }.map(\.id))
        let fromSecond = Set(pipe.frames.filter { $0.from == second.nodeId }.map(\.id))
        #expect(Set(forSecond.map(\.envelope.id)).isSubset(of: fromFirst), "every DM for the second, in its first rounds")
        #expect(Set(forFirst.map(\.envelope.id)).isSubset(of: fromSecond), "and every DM for the first")
    }

    /// Two full stores at the cap, each holding frames the other lacks, linked for forty lab minutes: the swap-loop test.
    /// Without the source counting in a frame's own write, a frame a full peer serves back has spread 0 while it is written
    /// and outranks every shared row, so the two swap a frame per exchange for good (`CarryLedger.sourceCountsInItsOwnWrite`).
    @Test func twoFullStoresAtTheCapSettleToTheLapseBoundAndBackOff() throws {
        let limits = CustodyLimits(maxFrames: 60)
        let lab = PipeLab()
        let wall = lab.clock.wallMilliseconds()
        let first = lab.node(1, custodyLimits: limits)
        let second = lab.node(2, custodyLimits: limits)
        for node in [first, second] {
            Self.pin(Self.senders, on: node)
        }
        let all = try Self.dms(100, to: TestPeer(seed: 999), label: "cap", sentAt: wall - 600_000, body: 100)
        var random = SeededGenerator(seed: 5)
        for node in [first, second] {
            Self.seed(node, with: all.filter { _ in Int.random(in: 0..<10, using: &random) < 7 })
        }
        #expect(first.stores.custody.liveIds(now: wall).count == 60 && second.stores.custody.liveIds(now: wall).count == 60)
        Self.settle(lab)
        let pipe = lab.link(first, second)
        let minute: Int64 = 60_000
        lab.run(step: 500, limit: 40 * minute) { false }
        let start = try #require(pipe.frames.first?.at)
        let settled = start + 5 * minute
        // Past the first answers: each id crosses each way at most once per lapse.
        for node in [first, second] {
            var last: [String: Int64] = [:]
            for frame in pipe.frames where frame.from == node.nodeId && frame.at >= settled && frame.type == .chat {
                if let before = last[frame.id] {
                    #expect(frame.at - before >= CarryLedger.notKeptLapseMilliseconds, "\(frame.id) again after \(frame.at - before) ms")
                }
                last[frame.id] = frame.at
            }
        }
        let late = pipe.frames.filter { $0.at >= start + 30 * minute && $0.type == .chat }
        #expect(late.count <= 2 * 60, "\(late.count) frames in the last ten minutes")
        // And the offers back off to the most once nothing new enters.
        for node in [first, second] {
            let times = pipe.digests.filter { $0.from == node.nodeId }.map(\.at)
            let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
            #expect(gaps.contains(ReofferBackoff.maxMilliseconds), "\(gaps)")
        }
    }

    // MARK: The back-off on the pipe

    @Test func aNeighbourThatNeverDrawsIsOfferedAtDoublingGapsAndAKeptFrameOrARelinkResets() throws {
        let lab = PipeLab()
        let first = lab.node(1)
        let second = lab.node(2)
        let pipe = lab.link(first, second)
        let minute: Int64 = 60_000
        lab.run(step: 1000, limit: 30 * minute) { false }
        let times = pipe.digests.filter { $0.from == first.nodeId }.map(\.at)
        let gaps = zip(times.dropFirst(), times).map { ($0 - $1) / 1000 }
        // The link-up's exchange draws once (each side keeps the other's profile), then nothing does.
        let doubling: [Int64] = [60, 120, 240, 480, 600]
        #expect((0...(gaps.count - doubling.count)).contains { Array(gaps[$0..<($0 + doubling.count)]) == doubling }, "\(gaps)")
        // A frame the second keeps from the first returns the second's interval to a minute at once.
        _ = try #require(first.engine.postToRoom("news"))
        let posted = lab.clock.monotonicMilliseconds()
        lab.run(step: 1000, limit: 2 * minute) { false }
        let next = pipe.digests.filter { $0.from == second.nodeId && $0.at > posted }.map(\.at)
        #expect(next.first.map { $0 - posted <= minute } == true, "offered within a tick")
        // A relink starts over.
        pipe.cut()
        let again = lab.link(first, second)
        lab.run(step: 1000, limit: 2 * minute) { false }
        let relinked = again.digests.filter { $0.from == first.nodeId }.map(\.at)
        #expect(relinked.count == 2 && relinked[1] - relinked[0] <= minute + ReofferBackoff.toleranceMilliseconds, "\(relinked)")
    }
}
