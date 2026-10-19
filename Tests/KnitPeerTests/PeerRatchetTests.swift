import Foundation
import KnitCrypto
import KnitMesh
import KnitPeer
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// `knit-peer`'s ratchet (ADR 2026-10.5sk9, phases P5b and P8): the switch is parsed, on unless `--no-ratchet`, `main`
/// loads the prekey ring kept beside the identity, and the profile the peer publishes carries the prekey and the ratchet's
/// bits, `0x15F`. Off, the profile is the pre-ratchet `0xF`, with no prekey.
@Suite struct PeerRatchetTests {
    private let home = ["HOME": "/home/tester"]

    private func run(_ arguments: [String]) throws -> RunOptions {
        guard case .run(let options) = try PeerCommand.parse(arguments, environment: home) else {
            throw UsageError.missing("run")
        }
        return options
    }

    @Test func theRatchetIsOnUnlessTurnedOff() throws {
        #expect(try run([]).ratchet)
        #expect(try run(["--ratchet"]).ratchet, "what an interop run still passes")
        #expect(try run(["run", "--name", "Peer", "--ratchet", "--feed", "pace"]).ratchet)
        #expect(try !run(["--no-ratchet"]).ratchet)
        #expect(try !run(["run", "--name", "Peer", "--no-ratchet", "--feed", "pace"]).ratchet)
        #expect(throws: UsageError.invalid(flag: "--ratchet", value: "--no-ratchet")) {
            try PeerCommand.parse(["--ratchet", "--no-ratchet"], environment: home)
        }
        for flag in ["--ratchet", "--no-ratchet"] {
            #expect(throws: UsageError.unknownFlag(flag)) {
                try PeerCommand.parse(["keygen", "--above", "cswad43wmlont27jr4tyvu63i4", flag], environment: home)
            }
        }
        #expect(PeerCommand.usage.contains("[--ratchet | --no-ratchet]"))
    }

    /// What one run of the peer left: the profile a far engine pinned from it, and its state directory.
    private struct Published {
        let pinned: PeerRecord
        let state: PeerState
        let directory: String
    }

    /// The node `main` makes from a state directory, as `KnitPeerMain.makeNode` wires it: the identity in the directory and,
    /// with `ratchet`, the ring `PeerState.loadPrekeys` reads beside it. Answers the profile a far engine pins from it.
    private func published(ratchet: Bool) async throws -> Published {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("knit-peer-\(UInt64.random(in: 0...UInt64.max))").path
        let state = PeerState(directory: directory)
        let rigKeys = identity(1)
        try state.replaceIdentity(with: rigKeys)
        #expect(try state.loadIdentity().keys.nodeId == rigKeys.nodeId)
        let prekeys = ratchet ? try state.loadPrekeys(for: rigKeys) : nil
        let rig = PeerRig(ownProfile: state.profileStore(), ratchet: ratchet, prekeys: prekeys)
        await rig.node.start(name: "Near")
        try await rig.link()
        rig.farEngine.start()
        rig.deliverToFar()
        let pinned = try #require(rig.farEngine.stores.peers.peer(rigKeys.nodeId), "the far side pinned the peer")
        return Published(pinned: pinned, state: state, directory: directory)
    }

    @Test func withTheSwitchThePeersProfileCarriesItsPrekeyAndTheRatchetsBits() async throws {
        let run = try await published(ratchet: true)
        defer { try? FileManager.default.removeItem(atPath: run.directory) }
        #expect(run.pinned.capabilities == 0x15F)
        let prekey = try #require(run.pinned.prekey, "the profile carries the prekey")
        #expect(PeerPrekey(verifying: prekey, signedBy: identity(1).bundle) != nil)
        #expect(try run.state.loadPrekeys(for: identity(1)).newest?.id == prekey.id, "minted at start, and kept beside the identity")
        #expect(run.state.profileStore().load().prekeyId == prekey.id)
    }

    @Test func withoutTheSwitchThePeersProfileIsTodays() async throws {
        let run = try await published(ratchet: false)
        defer { try? FileManager.default.removeItem(atPath: run.directory) }
        #expect(run.pinned.capabilities == 0xF && run.pinned.prekey == nil)
        #expect(try run.state.loadPrekeys(for: identity(1)).prekeys.isEmpty, "nothing minted")
    }
}
