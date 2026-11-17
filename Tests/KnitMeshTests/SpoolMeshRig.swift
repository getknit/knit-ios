import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Two ``Mesh``es, Alice (0) and Bob (1), whose ratchet sessions confirmed over radio in a ``SpoolLab``, then rebuilt as
/// actors over the same stores on one manual clock, with no radio link, each dialling the one relay through a ``SpoolNet``
/// door (ADR 2026-11.adrq, P4b1). The sockets' tasks are the meshes' own; ``settle()`` waits until nothing moves.
final class SpoolMeshRig {
    static let relay = SpoolRelayHandle(number: 1)

    let lab: SpoolLab
    let clock: ManualClock
    let spool: FakeSpool
    let net: SpoolNet
    let logs: [RecordingLog]
    let meshes: [Mesh]

    /// The rig, both meshes started and their relay added, settled.
    static func make(spool: FakeSpool? = nil, bobStores: MeshStores = .inMemory()) async throws -> SpoolMeshRig {
        try await make(SpoolEngineLabTests.greeted(bobStores: bobStores), nodes: [0, 1], spool: spool)
    }

    /// Meshes for `lab`'s nodes `nodes`, over `spool` (a fresh one when `nil`), started, their relay added, settled. Mesh `n`
    /// of the rig is lab node `nodes[n]`.
    static func make(_ lab: SpoolLab, nodes: [Int], spool: FakeSpool?) async throws -> SpoolMeshRig {
        let rig = SpoolMeshRig(lab, nodes: nodes, spool: spool)
        let url = try #require(SpoolLab.url)
        for mesh in rig.meshes {
            await mesh.start()
            #expect(await mesh.addSpoolRelay(Self.relay, url: url))
        }
        await rig.settle()
        return rig
    }

    private init(_ lab: SpoolLab, nodes: [Int], spool: FakeSpool?) {
        self.lab = lab
        clock = ManualClock(wall: lab[0].clock.wallMilliseconds(), monotonic: lab[0].clock.monotonicMilliseconds())
        let given = spool ?? FakeSpool(now: clock.wallMilliseconds())
        self.spool = given
        net = SpoolNet(spool: given)
        logs = nodes.map { _ in RecordingLog() }
        var made: [Mesh] = []
        for (tag, index) in nodes.enumerated() {
            made.append(
                Mesh(
                    identity: lab[index].me.keys,
                    prekeys: lab[index].engine.prekeyRing,
                    deviceTag: "0011223344556677",
                    stores: lab[index].stores,
                    radio: FakeRadio(advertisesServiceData: false),
                    clock: clock,
                    random: SeededGenerator(seed: UInt64(100 + index)),
                    configuration: MeshConfiguration(ratchet: true),
                    log: logs[tag],
                    spoolSockets: net.door(tag)
                ))
        }
        meshes = made
    }

    subscript(_ index: Int) -> Mesh {
        meshes[index]
    }

    /// Waits until no socket, timer or post moves for a while.
    func settle(sourceLocation: SourceLocation = #_sourceLocation) async {
        var last: [Int] = []
        var stable = 0
        for _ in 0..<Self.maxPolls {
            var now = net.activity
            var sending = false
            for mesh in meshes {
                now.append(await mesh.timerFirings)
                let queued = await mesh.spoolStatus.relays.reduce(0) { $0 + ($1.counts["queuedBytes"] ?? 0) }
                sending = sending || (queued > 0 && !net.neverReads)
            }
            await Task.yield()
            if now == last, !sending {
                stable += 1
                if stable >= Self.stablePolls {
                    return
                }
            } else {
                stable = 0
                last = now
            }
        }
        Issue.record("the rig never went quiet", sourceLocation: sourceLocation)
    }

    private static let maxPolls = 200_000
    private static let stablePolls = 40

    /// Moves the clock and the spool's on by `milliseconds`, and settles. Records still waiting on a socket are read first in
    /// steps of the inbound budget's refill, as a clock that runs on would let a reader read them, so a long step never
    /// lets a request's timeout overtake answers that wait only on the budget; ``rawAdvance(_:)`` skips that.
    func advance(_ milliseconds: Int64) async {
        await drainInbound()
        await rawAdvance(milliseconds)
        await drainInbound()
    }

    /// Moves the clocks on by `milliseconds` and settles, nothing more.
    func rawAdvance(_ milliseconds: Int64) async {
        clock.advance(milliseconds)
        net.advance(to: clock.wallMilliseconds())
        await settle()
    }

    private func drainInbound() async {
        for _ in 0..<Self.maxDrainSteps where net.queued > 0 {
            await rawAdvance(SpoolInboundBudget.refillMilliseconds)
        }
    }

    private static let maxDrainSteps = 30

    /// Steps `count` times, `milliseconds` apart.
    func run(_ count: Int, every milliseconds: Int64 = ScopeHeal.healFloorMilliseconds) async {
        for _ in 0..<count {
            await advance(milliseconds)
        }
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

    /// The pair's live ids in node `index`'s custody.
    func pairIds(_ index: Int) -> Set<String> {
        lab.pairIds(index, with: 1 - index)
    }

    /// The spool's digest of the pair's scope, and each mesh's fold of it.
    struct Folds {
        let spool: UInt64
        let alice: UInt64?
        let bob: UInt64?
    }

    func folds() async -> Folds {
        let scope = spoolScope()
        let digest = scope.map { ScopeCrypto.digest(of: spool.liveIds($0).map(\.bytes)) } ?? 0
        var each: [UInt64?] = []
        for mesh in meshes {
            each.append(await mesh.spoolFold(scope))
        }
        return Folds(spool: digest, alice: each[0], bob: each[1])
    }

    /// The scope the spool holds, its only one.
    func spoolScope() -> SpoolID? {
        net.withSpool { $0.scopes.keys.first }
    }

    /// The spool lines of mesh `index`'s log.
    func spoolLines(_ index: Int) -> [String] {
        logs[index].all.filter { $0.contains("spool") }
    }

    /// Every line of mesh `index`'s log.
    func allLines(_ index: Int) -> [String] {
        logs[index].all
    }
}

extension Mesh {
    /// The local fold `scope`'s last heal on the rig's relay compared.
    func spoolFold(_ scope: SpoolID?) -> UInt64? {
        scope.flatMap { spool.relays[SpoolMeshRig.relay]?.heal.localFold($0) }
    }

    /// The scopes the plane's table carries.
    var spoolScopes: [SpoolID] { spool.table.scopes.map(\.id) }
}
