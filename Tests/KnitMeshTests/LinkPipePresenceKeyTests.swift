import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Our own presence keys between two whole nodes on a SEALED link (ADR 2026-11.prsp; the `link-seal` contract, §4): the
/// writer's ctl 11, a v3 ratchet DM that never relays and goes only under a confirmed session over the proven link, crosses
/// inside frames and opens at the far engine, which stores and lists the sender's key. The pipe reads it with keys of its
/// own; nothing of it is on the air in the clear.
@Suite struct LinkPipePresenceKeyTests {
    private static let configuration = MeshConfiguration(ratchet: true, sendsOwnPresenceKeys: true, logsPresenceKeyTrail: true)

    /// A ratcheting phone of `seed`'s on `lab`'s clock, keeping its prekeys, with a device tag of its own.
    private func node(_ lab: PipeLab, _ seed: Int) throws -> PipeNode {
        let peer = TestPeer(seed: seed)
        let ring = try PrekeyRing.load(for: peer.keys, from: KeptSecretStore(peer.keys.storedForm))
        let tag = String(repeating: "0", count: 14) + String(seed, radix: 16).suffix(2)
        return lab.add(
            PipeNode(peer, clock: lab.clock, seed: UInt64(seed), configuration: Self.configuration, prekeys: ring, deviceTag: tag))
    }

    /// Each node's presence-key pass, as the `Mesh` actor runs it after every entry, then the pipe carried.
    private func pass(_ lab: PipeLab, _ nodes: PipeNode...) {
        for node in nodes {
            node.engine.feedPresenceKeys()
        }
        lab.pump()
    }

    @Test func ourCtl11CrossesASealedLinkAndTheFarEngineStoresOurKey() throws {
        let lab = PipeLab(sealed: true)
        let alice = try node(lab, 1)
        let bob = try node(lab, 2)
        let pipe = lab.link(alice, bob)
        #expect(pipe.sealed, "the oracle is a sealed link: a plain run passes nothing")
        #expect([alice.links.linksSealed, bob.links.linksSealed] == [1, 1])
        #expect(lab.run(limit: 60_000) { alice.stores.peers.peer(bob.nodeId) != nil && bob.stores.peers.peer(alice.nodeId) != nil })

        // A confirmed session: Bob accepts Alice, she greets him, and his side answers over the link.
        bob.engine.accept(alice.nodeId.string)
        _ = try #require(alice.engine.sendDirectMessage("hello", to: bob.nodeId))
        let stored = lab.run(limit: 120_000) {
            pass(lab, alice, bob)
            return bob.stores.presenceKeys.keys(of: alice.nodeId).first != nil
        }
        #expect(stored, "Alice's keys reached Bob")
        #expect(alice.engine.ratchet.session(of: bob.nodeId)?.confirmed == true)

        // Bob's engine opened the ctl 11 and stored her key: only the ratchet open's `applyPresenceKey` stores one.
        #expect(bob.engine.presenceKeyCounts.stored >= 1)

        // The frame the trail names crossed the pipe from Alice, read inside the frames, and never in the clear.
        let line = try #require(alice.log.all.first { $0.contains("mesh presence keys sealed to \(bob.nodeId): frame ") })
        let after = try #require(line.split(separator: "frame ", omittingEmptySubsequences: false).last)
        let id = try #require(after.split(separator: ",").first.map(String.init))
        #expect(pipe.frames.contains { $0.from == alice.nodeId && $0.to == bob.nodeId && $0.id == id }, "it crossed, sealed")
        let channel = try #require(pipe.channel(of: alice))
        let air = alice.radio.writes(on: channel).flatMap(\.self)
        #expect(alice.radio.records(on: channel).map(\.tag).allSatisfy { $0 == .keyShare || $0 == .sealed })
        #expect(!Self.contains(air, Array(id.utf8)), "the ctl 11's id is nowhere on the air")
        #expect([alice.links.linkSealFailed, bob.links.linkSealFailed] == [0, 0])
        #expect([alice.links.linksSealed, bob.links.linksSealed] == [1, 1], "still the one sealed link")
    }

    /// Whether `haystack` holds `needle` anywhere.
    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else {
            return false
        }
        return (0...(haystack.count - needle.count)).contains { haystack[$0..<($0 + needle.count)].elementsEqual(needle) }
    }
}
