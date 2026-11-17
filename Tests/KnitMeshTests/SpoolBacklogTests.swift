import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Test 6 of P4b1 (ADR 2026-11.adrq): a cold launch that finds a 2,000-frame backlog on the spool while a radio peer floods
/// 1,000 frames. The spool's own seen set takes the backlog, so no radio id is admitted twice inside the window, and the
/// spool serves each unheld blob about once.
@Suite struct SpoolBacklogTests {
    static let bob = SpoolEngineLabTests.bob
    static let peers = (0..<10).map { TestPeer(seed: 81 + $0) }
    static let perPeer = CustodyLimits().maxPerSender
    static let flooder = TestPeer(seed: 99)

    /// Bob (0) and ten peers, each pair's session confirmed over radio, then apart; every peer sends Bob `perPeer` DMs
    /// over the spool while Bob is away.
    static func backlog() throws -> SpoolLab {
        var fixtures = [try EngineFixture.ratcheting(bob, seed: 12)]
        for (index, peer) in peers.enumerated() {
            fixtures.append(try EngineFixture.ratcheting(peer, seed: 21 + UInt64(index)))
        }
        let lab = SpoolLab(fixtures)
        for node in 1...peers.count {
            lab.radio.link(0, node)
            try SpoolEngineLabTests.send(lab, 0, node, "hello")
            try SpoolEngineLabTests.send(lab, node, 0, "hi")
            lab.advance(SpoolEngineLabTests.minute)
            try SpoolEngineLabTests.send(lab, 0, node, "again")
            try SpoolEngineLabTests.send(lab, node, 0, "and again")
            lab.advance(SpoolEngineLabTests.minute)
            lab.radio.unlink(0, node)
        }
        SpoolEngineLabTests.online(lab, Array(1...peers.count))
        for node in 1...peers.count {
            for index in 0..<perPeer {
                lab[node].engine.sendDirectMessage("backlog \(node).\(index)", to: bob.nodeId)
            }
        }
        lab.pump()
        lab.run(24)
        return lab
    }

    @Test func aColdLaunchBacklogNeverLetsARadioIdInTwice() async throws {
        let lab = try Self.backlog()
        let wall = lab[0].clock.wallMilliseconds()
        let held = Set(lab[0].stores.custody.liveFrames(now: wall).map(\.envelope.id))
        var unheld: [[UInt8]] = []
        for scope in lab.scopes(0) {
            for blob in lab.spool.scopes[scope.id]?.live ?? [] {
                guard let opened = ScopeCrypto.open(scope.keys, blobId: blob.id.bytes, blob: blob.data),
                    let envelope = try? RelayEnvelope(decoding: opened.signed), !held.contains(envelope.id)
                else {
                    continue
                }
                unheld.append(blob.data)
            }
        }
        #expect(unheld.count >= 1900, "a backlog of about 2,000 unheld frames: \(unheld.count)")
        let backlog = unheld.reduce(0) { $0 + $1.count }
        #expect(lab.spool.scopes.values.reduce(0) { $0 + $1.live.count } >= 2000, "the backlog sits on the spool")

        // Bob cold-launches as a mesh, with peer 1 a mesh too, over the spool the backlog sits on.
        let rig = try await SpoolMeshRig.make(lab, nodes: [0, 1], spool: lab.spool)
        let channel = ChannelID(70)
        await rig[0].process(.accepted(channel))
        let hello = Hello(nodeId: Self.flooder.nodeId.string, capabilities: Capabilities(rawValue: AndroidPeer.capabilities)).payload
        await rig[0].process(.received(channel, LinkRecord(.hello, payload: hello).encoded ?? []))
        let flood = try (0..<1000).map { try Self.flooder.profile(publishedAt: wall + Int64($0)) }
        let admitted = await rig[0].routerCounters.admitted
        for pass in 0..<2 {
            for frame in flood {
                await rig[0].process(.received(channel, LinkRecord(.frame, payload: frame.wire.encoded).encoded ?? []))
            }
            if pass == 0 {
                await rig.run(12, every: 30_000)
            }
        }
        let counters = await rig[0].routerCounters
        #expect(counters.admitted - admitted == flood.count, "each radio id admitted once inside the window")
        #expect(counters.spoolAdmitted > 0, "the backlog came in meanwhile")

        // Pulls are held to the hour's budget, so the rest of the backlog takes the hours that follow. The steps stay under a
        // request's 30 s, so a reader that waits a second for its inbound budget is never leapfrogged by its own timeout, as
        // a clock that runs on never leapfrogs it.
        await rig.run(Int(10 * SpoolIntake.windowMilliseconds / 20_000), every: 20_000)
        let after = Set(lab[0].stores.custody.liveFrames(now: rig.clock.wallMilliseconds()).map(\.envelope.id))
        let served = rig.net.served(to: 0)
        #expect(served <= backlog + backlog / 10, "bob was served at most 1.1 × the backlog: \(served) of \(backlog)")
        #expect(after.count > held.count, "the backlog landed")
    }
}
