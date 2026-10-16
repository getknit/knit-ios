import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// How far a re-seal after a reset reaches (ADR 2026-10.5sk9, phase P5b; the P5b blobs review's first finding), on three
/// engines in a line: the iPhone (0), a carrier (1) and a peer (2), each linked only to its neighbours. The re-seal keeps
/// its DM's id, and a router drops a frame by its id alone for ten minutes (`Router.swift:120`, `MeshRouter.kt:100`): the
/// peer whose open failed lets one copy back past its own router, but a carrier never does, and every custody keeps the
/// original's bytes. So a re-seal reaches only the nodes it meets live whose router has not seen its id within ten
/// minutes, in this port as in Kotlin.
@Suite struct RatchetResealReachTests {
    private let iphone = TestPeer(seed: 1)
    private let peer = TestPeer(seed: 2)
    private let carrier = TestPeer(seed: 3)
    private static let minute: Int64 = 60_000
    /// Longer than any relay's jitter, so a flood crosses a hop in one step.
    private static let hop: Int64 = 200

    /// The line, greeted end to end through the carrier, with the peer then reinstalled while it is linked to the carrier
    /// alone: a fresh database, the Keychain's identity and prekeys kept.
    private func reinstalledLine() throws -> EngineLab {
        let keychain = KeptSecretStore(peer.keys.storedForm)
        let lab = EngineLab([
            try EngineFixture.ratcheting(iphone, seed: 11),
            try EngineFixture.ratcheting(carrier, seed: 13),
            try EngineFixture.ratcheting(peer, keychain: keychain, seed: 12),
        ])
        lab.link(0, 1)
        lab.link(1, 2)
        lab.advance(Self.hop)
        try send(lab, 0, 2, "hello")
        try send(lab, 2, 0, "hi")
        try send(lab, 0, 2, "and back")
        lab.expectConverged(0, 2, atLeast: 3, "greeted through the carrier")

        lab.advance(Self.minute)
        let wall = lab[2].clock.wallMilliseconds()
        lab.replace(2, with: try EngineFixture.ratcheting(peer, keychain: keychain, wall: wall, seed: 22))
        lab.link(1, 2)
        lab.advance(Self.hop)
        #expect(lab[2].stores.peers.peer(iphone.nodeId) != nil, "the reinstalled peer pinned the iPhone again, from the carrier")
        return lab
    }

    /// Node `from` sends `text` to node `to`, the floods crossing the carrier, and answers its id.
    @discardableResult
    private func send(_ lab: EngineLab, _ from: Int, _ to: Int, _ text: String) throws -> String {
        let record = try #require(lab[from].engine.sendDirectMessage(text, to: lab[to].me.nodeId))
        lab.advance(Self.hop)
        lab.advance(Self.hop)
        return record.id
    }

    /// Kotlin's level, pinned (the blobs review): three DMs cross the carrier live, and the reinstalled peer resets at the
    /// third. The iPhone seals all three again, but the carrier relayed their originals inside its ten-minute window and
    /// drops the copies as duplicates, every custody holds only the originals, and the peer never reads the three. Kotlin's
    /// `resealRecentDmsTo` promises "recoverable copies back on the mesh" (`MeshManager.kt:3354-3360`), and its copies die
    /// at such a carrier too. A fix in knit-next, a re-seal that carriers let past their window say, would flip this test,
    /// and the port would follow it.
    @Test func atKotlinsLevelAReSealDiesAtACarrierThatRelayedItsOriginalWithinTenMinutes() throws {
        let lab = try reinstalledLine()
        let ids = try (1...3).map { try send(lab, 0, 2, "while you were gone \($0)") }
        let originals = Dictionary(uniqueKeysWithValues: ids.map { id in (id, lab.chats(from: 0, to: 2, id: id).first?.wire.signed) })
        #expect(Set(lab[2].resetsSent(to: iphone).map(\.envelope.id)).count == 1, "the third NO_SESSION reset the pair")
        let deduplicated = lab[1].engine.routerCounters.deduplicated
        lab.advance(Self.hop)
        lab.advance(Self.hop)
        #expect(ids.allSatisfy { lab.seals(from: 0, to: 2, id: $0) == 2 }, "the iPhone sealed each again once")

        #expect(lab[1].engine.routerCounters.deduplicated == deduplicated + 3, "the three copies died at the carrier's router")
        let relayed = lab[1].transport.written(.chat).filter { ids.contains($0.envelope.id) }
        #expect(relayed.count == 3, "the carrier relayed the three originals and no copy")
        #expect(relayed.allSatisfy { originals[$0.envelope.id] == $0.wire.signed })
        for node in 0...2 {
            let now = lab[node].clock.wallMilliseconds()
            #expect(ids.allSatisfy { lab[node].stores.custody.frame($0, now: now)?.signed == originals[$0] }, "\(node) holds the originals")
        }
        lab.advance(Self.minute)
        #expect(ids.allSatisfy { id in !lab.thread(2, with: 0).contains { $0.hasPrefix(id) } }, "the peer never reads them")
    }

    /// The same three DMs crossing the carrier more than ten minutes before the peer's reset gets out: by then the carrier's
    /// window for their ids has passed, so it relays the copies and the peer reads all three.
    @Test func aReSealCrossesACarrierWhoseWindowForItsOriginalHasPassed() throws {
        let lab = try reinstalledLine()
        lab.hold(from: 2, to: 1)
        let ids = try (1...3).map { try send(lab, 0, 2, "while you were gone \($0)") }
        #expect(Set(lab[2].resetsSent(to: iphone).map(\.envelope.id)).count == 1, "the third NO_SESSION reset the pair")
        #expect(ids.allSatisfy { lab.seals(from: 0, to: 2, id: $0) == 1 }, "its reset is held: nothing sealed again yet")

        lab.advance(11 * Self.minute)
        lab.release(from: 2, to: 1)
        lab.advance(Self.hop)
        lab.advance(Self.hop)
        lab.advance(Self.hop)
        #expect(ids.allSatisfy { lab.seals(from: 0, to: 2, id: $0) == 2 }, "the iPhone sealed each again once")
        let read = lab.thread(2, with: 0)
        #expect(ids.allSatisfy { id in read.contains { $0.hasPrefix(id) } }, "the peer reads all three: \(read)")
    }
}
