import Foundation
import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// The reference daemon `check.sh spool` runs against (ADR 2026-11.adrq, P5): its addresses, from the environment, each on
/// this machine's loopback or refused.
enum SpoolDaemon {
    /// The public daemon every case dials, at `SPOOL_POW_BITS=8`.
    static let url = loopback("KNIT_SPOOL_URL")
    /// A second public daemon, for the two-relay case.
    static let secondURL = loopback("KNIT_SPOOL_URL_2")
    /// A daemon run with `SPOOL_TOKEN`, and the token, for the private relay's case.
    static let privateURL = loopback("KNIT_SPOOL_PRIVATE_URL")
    static let token = ProcessInfo.processInfo.environment["KNIT_SPOOL_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
    /// A daemon at `SPOOL_POW_BITS=24`, dialled only when `KNIT_SPOOL_HEAVY=1`.
    static let heavyURL = ProcessInfo.processInfo.environment["KNIT_SPOOL_HEAVY"] == "1" ? loopback("KNIT_SPOOL_HEAVY_URL") : nil

    /// Whether any daemon variable names an address that is not this machine's loopback, which the suite refuses to dial.
    static let refused = ["KNIT_SPOOL_URL", "KNIT_SPOOL_URL_2", "KNIT_SPOOL_PRIVATE_URL", "KNIT_SPOOL_HEAVY_URL"].filter { name in
        ProcessInfo.processInfo.environment[name].map { SpoolTestSockets.Target($0) == nil } == true
    }

    /// The text in `name`, when it is a `ws://` address on `127.0.0.1` or `localhost`.
    private static func loopback(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name].flatMap { SpoolTestSockets.Target($0) == nil ? nil : $0 }
    }
}

/// Two ``Mesh``es, Alice (0) and Bob (1), whose ratchet sessions confirmed over radio in a ``SpoolLab``, rebuilt as actors over
/// the same stores and dialling the reference daemon through ``SpoolTestSockets``, as ``SpoolMeshRig`` dials ``FakeSpool``.
/// Their clock starts at the real time, so the daemon takes their stamps' UTC day, and moves only when the test moves it;
/// the daemon is outside that clock, so ``settle()`` waits until the sockets go quiet.
final class SpoolDaemonRig {
    static let relay = SpoolRelayHandle(number: 1)
    static let secondRelay = SpoolRelayHandle(number: 2)

    let lab: SpoolLab
    let clock: ManualClock
    let sockets = SpoolTestSockets()
    let radios: [FakeRadio]
    let logs: [RecordingLog]
    let meshes: [Mesh]

    /// The rig, the meshes in `online` (every one when `nil`) started with `relays` added, settled. Each run draws fresh
    /// ratchet roots, so its scopes are new to a daemon that served an earlier run.
    static func make(relays: [String], peers: Int = 1, online: [Int]? = nil) async throws -> SpoolDaemonRig {
        let rig = try SpoolDaemonRig(peers: peers)
        for (index, mesh) in rig.meshes.enumerated() where online?.contains(index) != false {
            await mesh.start()
            for (number, text) in relays.enumerated() {
                let url = try #require(AcceptedSpoolURL(text, allowCleartext: true))
                #expect(await mesh.addSpoolRelay(number == 0 ? relay : secondRelay, url: url))
            }
        }
        await rig.settle()
        return rig
    }

    /// Alice and `peers` others, each greeted by Alice over radio.
    private init(peers: Int) throws {
        let wall = Int64(Date().timeIntervalSince1970 * 1000)
        let seed = UInt64(truncatingIfNeeded: wall)
        let people =
            [SpoolEngineLabTests.alice, SpoolEngineLabTests.bob, SpoolEngineLabTests.carol]
            + (3..<max(3, peers + 1)).map { TestPeer(seed: 40 + $0) }
        var fixtures: [EngineFixture] = []
        for (index, person) in people.prefix(peers + 1).enumerated() {
            fixtures.append(try EngineFixture.ratcheting(person, wall: wall, seed: seed &+ UInt64(index)))
        }
        lab = SpoolLab(fixtures, spool: nil)
        for peer in 1...peers {
            lab.radio.link(0, peer)
            for round in 0..<2 {
                try SpoolEngineLabTests.send(lab, 0, peer, "hello \(round)")
                try SpoolEngineLabTests.send(lab, peer, 0, "hi \(round)")
                lab.advance(SpoolEngineLabTests.minute)
            }
            #expect(lab.radio.sessionsAgree(0, peer) && lab.radio.bothHoldSessions(0, peer), "the session confirmed over radio")
            lab.radio.unlink(0, peer)
        }
        clock = ManualClock(wall: lab[0].clock.wallMilliseconds(), monotonic: lab[0].clock.monotonicMilliseconds())
        radios = fixtures.map { _ in FakeRadio(advertisesServiceData: false) }
        logs = fixtures.map { _ in RecordingLog() }
        var made: [Mesh] = []
        for index in fixtures.indices {
            made.append(
                Mesh(
                    identity: lab[index].me.keys,
                    prekeys: lab[index].engine.prekeyRing,
                    deviceTag: "0011223344556677",
                    stores: lab[index].stores,
                    radio: radios[index],
                    clock: clock,
                    random: SeededGenerator(seed: seed &+ UInt64(100 + index)),
                    configuration: MeshConfiguration(ratchet: true),
                    log: logs[index],
                    spoolSockets: sockets
                ))
        }
        meshes = made
    }

    subscript(_ index: Int) -> Mesh {
        meshes[index]
    }

    /// Waits until the sockets and the meshes' queues stay still for ``quietPolls`` polls in a row, at most ``maxPolls``.
    func settle(sourceLocation: SourceLocation = #_sourceLocation) async {
        var last: SpoolTestSockets.Activity?
        var quiet = 0
        for _ in 0..<Self.maxPolls {
            let now = sockets.now
            var queued = 0
            for mesh in meshes {
                queued += await mesh.spoolStatus.relays.reduce(0) { $0 + ($1.counts["queuedBytes"] ?? 0) }
            }
            if now == last, now.sending == 0, queued == 0 {
                quiet += 1
                if quiet >= Self.quietPolls {
                    return
                }
            } else {
                quiet = 0
                last = now
            }
            // The daemon answers on its own time, outside the meshes' clock: this waits for its answers, not for a timer.
            try? await Task.sleep(for: .milliseconds(Self.pollMilliseconds))
        }
        Issue.record("the daemon never went quiet", sourceLocation: sourceLocation)
    }

    private static let maxPolls = 1500
    private static let quietPolls = 10
    private static let pollMilliseconds = 20

    /// Moves the clock on by `milliseconds`, then settles.
    func advance(_ milliseconds: Int64) async {
        clock.advance(milliseconds)
        await settle()
    }

    /// Steps `count` times, `milliseconds` apart.
    func run(_ count: Int, every milliseconds: Int64 = ScopeHeal.healFloorMilliseconds) async {
        for _ in 0..<count {
            await advance(milliseconds)
        }
    }

    /// Steps until `holds` reads true, at most `steps` times; answers whether it did.
    func until(steps: Int = 40, _ holds: () async -> Bool) async -> Bool {
        for _ in 0..<steps {
            if await holds() {
                return true
            }
            await advance(ScopeHeal.healFloorMilliseconds)
        }
        return await holds()
    }

    /// Mesh `from` sends `text` to mesh `to`, and answers its id.
    func send(_ from: Int, _ to: Int, _ text: String) async throws -> String {
        let record = try #require(await meshes[from].sendDirectMessage(text, to: lab[to].me.nodeId))
        await settle()
        return record.id
    }

    /// Whether mesh `index`'s store holds the message `id`.
    func holds(_ index: Int, _ id: String) -> Bool {
        lab[index].stores.messages.message(id) != nil
    }

    /// The scopes mesh `index`'s table carries.
    func scopes(_ index: Int) async -> [SpoolScope] {
        await meshes[index].spoolTable
    }
}

extension Mesh {
    /// The scopes the plane's table carries, keys and all.
    var spoolTable: [SpoolScope] { spool.table.scopes }

    /// The local fold of `scope` on `relay`'s heal.
    func spoolFold(_ scope: SpoolID, on relay: SpoolRelayHandle) -> UInt64? {
        spool.relays[relay]?.heal.localFold(scope)
    }
}
