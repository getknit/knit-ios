import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The group form sent and received by three iPhones with the switch on, under the mesh's delivery pathology (ADR
/// 2026-10.5sk9, phase P6b): knit-next's `GroupRatchetSoakTest` properties at the mesh's level, on engines rather than the
/// engine alone, with the lab's courier holding every link each round and handing the frames over shuffled, some dropped and
/// some twice, on Kotlin's seeds, drawn through ``SeededGenerator``. A member leaves mid-run. Custody's back-fill, the seed
/// re-sends and the instant replays are what must bring every member level.
///
/// Per seed: every message any member sent while in the group reaches every other member still in it, exactly once; a
/// member who left is sent no seed after the others processed its departure; no seed is lost as stale; and the custodies
/// agree.
@Suite struct GroupSendSoakTests {
    private typealias Carried = EngineLab.Carried

    private let peers = [TestPeer(seed: 1), TestPeer(seed: 5), TestPeer(seed: 6)]
    private var hop: Int64 { Router.Configuration().jitterWindowMilliseconds + 1 }
    private static let rounds = 6
    /// The round before which node 2 leaves.
    private static let leaveRound = 3

    @Test(arguments: [1, 7, 42, 1337, 99_991, 4242] as [UInt64])
    func groupTrafficConvergesUnderDropsReordersDuplicatesAndHolds(seed: UInt64) throws {
        var random = SeededGenerator(seed: seed)
        var dropped = 0
        let lab = EngineLab(try peers.enumerated().map { try EngineFixture.ratcheting($1, seed: seed &+ UInt64($0)) })
        let links = [(0, 1), (1, 2), (0, 2)]
        for (first, second) in links {
            lab.link(first, second)
        }
        lab.advance(hop)
        let group = try #require(lab[0].engine.createGroup(with: [peers[1].nodeId, peers[2].nodeId])).id
        // The founding message makes the group everywhere, so every member can write in round 0.
        let founded = try #require(lab[0].engine.sendGroupMessage("founded", to: group))
        lab.advance(hop)
        lab.advance(hop)
        #expect((1...2).allSatisfy { lab[$0].stores.groups.group(group) != nil })
        var sent = [founded.id]
        for round in 0..<Self.rounds {
            let directions = links.flatMap { [($0.0, $0.1), ($0.1, $0.0)] }
            for (from, to) in directions {
                lab.hold(from: from, to: to)
            }
            if round == Self.leaveRound {
                #expect(lab[2].engine.leaveGroup(group))
            }
            for index in 0..<3 where round < Self.leaveRound || index != 2 {
                let record = try #require(lab[index].engine.sendGroupMessage("r\(round) n\(index)", to: group))
                sent.append(record.id)
            }
            for (from, to) in directions {
                lab.release(from: from, to: to) { Self.mangle($0, with: &random, dropped: &dropped) }
            }
            lab.advance(hop)
        }
        let keyless = (0...2).map { lab[$0].engine.dropped[.groupRatchetNoKey] ?? 0 }.reduce(0, +)
        #expect(dropped > 0 && keyless > 0, "seed \(seed): the courier lost nothing, or every frame met its seed: the harness is broken")
        settle(lab)
        for member in [0, 1] {
            let held = lab[member].stores.messages.messages(in: group).filter { $0.kind == .message }.map(\.id)
            let owed = sent
            #expect(Set(held) == Set(owed) && held.count == owed.count, "seed \(seed): node \(member) holds every message once")
            #expect(lab[member].engine.dropped[.groupRatchetAeadFail] == nil, "seed \(seed): node \(member) lost no seed as stale")
            #expect(lab[member].stores.groupRatchet.keySend(group, member: peers[2].nodeId) == nil, "seed \(seed): no seed to the leaver")
        }
        #expect(lab[2].stores.groups.group(group)?.hasLeft == true && lab[2].stores.groupRatchet.holdings(of: group).recvChains.isEmpty)
        let custodies = (0...2).map { Set(lab.liveIds($0)) }
        #expect(custodies.allSatisfy { $0 == custodies[0] }, "seed \(seed): the custodies agree")
    }

    /// The courier's round: the frames shuffled, each dropped one time in four and handed over twice one time in six;
    /// digests always cross, as the lab lets them.
    private static func mangle(_ items: [Carried], with random: inout SeededGenerator, dropped: inout Int) -> [Carried] {
        var out: [Carried] = []
        for item in items.shuffled(using: &random) {
            let roll = random.next(upperBound: UInt64(12))
            if roll < 3 {
                dropped += 1
                continue
            }
            out.append(item)
            if roll < 5 {
                out.append(item)
            }
        }
        return out
    }

    /// Lets the mesh heal: custody's exchanges, the hourly replay and a seed floor's worth of re-offers.
    private func settle(_ lab: EngineLab) {
        for _ in 0..<4 {
            lab.advance(MeshConfiguration().reofferMilliseconds)
            lab.advance(hop)
        }
        lab.advance(GroupRatchetOutbound.seedResendMilliseconds)
        for _ in 0..<3 {
            lab.advance(MeshConfiguration().reofferMilliseconds)
            lab.advance(hop)
        }
        lab.advance(RatchetSessions.sweepMilliseconds)
        lab.advance(hop)
        lab.advance(MeshConfiguration().reofferMilliseconds)
        lab.advance(hop)
    }
}
