import KnitStore
import KnitWire

@testable import KnitMesh

/// The phones and their pipes on one manual clock.
final class PipeLab {
    let clock = ManualClock(wall: EngineFixture.start, monotonic: 1000)
    private(set) var pipes: [LinkPipe] = []
    private var nodes: [PipeNode] = []
    private var nextChannel: UInt64 = 10
    /// Whether the lab's links open sealed unless a link says otherwise (``LinkPipe/sealed``).
    let sealed: Bool

    /// A lab whose links open sealed, or plain with both nodes' seal off.
    init(sealed: Bool = false) {
        self.sealed = sealed
    }

    /// A started phone for `seed`, its custody under `custodyLimits`.
    func node(_ seed: Int, custodyLimits: CustodyLimits = CustodyLimits()) -> PipeNode {
        add(PipeNode(TestPeer(seed: seed), clock: clock, seed: UInt64(seed), custodyLimits: custodyLimits))
    }

    /// Starts `node`, made on this lab's clock, and keeps it in the lab's passes.
    func add(_ node: PipeNode) -> PipeNode {
        node.start()
        nodes.append(node)
        return node
    }

    @discardableResult
    func link(_ dialer: PipeNode, _ answerer: PipeNode, cutAfter: Int? = nil, holding: PipeNode? = nil) -> LinkPipe {
        let pipe = LinkPipe(dialer, answerer, channel: nextChannel, clock: clock, sealed: sealed)
        pipe.cutAfter = cutAfter
        nextChannel += 2
        pipes.append(pipe)
        // The handshake crosses first, its proofs and what came behind them, whatever is held after: a pass a leg.
        _ = (0..<12).first { _ in pipe.isLinked || !pipe.pumpOnce() }
        pipe.holding = holding
        pump()
        return pipe
    }

    /// Carries everything waiting on every pipe until nothing more crosses.
    func pump() {
        while pipes.map({ $0.pumpOnce() }).contains(true) {
            // Again: what crossed may have written more.
        }
    }

    /// Steps the lab `step` ms at a time, carrying and firing timers, until `done` holds or `limit` ms pass. Answers
    /// whether `done` held.
    @discardableResult
    func run(step: Int64 = 20, limit: Int64 = 600_000, until done: () -> Bool) -> Bool {
        var elapsed: Int64 = 0
        pump()
        while !done() {
            guard elapsed < limit else {
                return false
            }
            clock.advance(step)
            elapsed += step
            for node in nodes {
                node.fireDueTimers()
            }
            pump()
        }
        return true
    }

    /// Every serve of `hash` that crossed any pipe, in the order the pipes were made.
    func serves(of hash: BlobHash) -> [LinkPipe.Serve] {
        pipes.flatMap { $0.serves.filter { $0.hash == hash } }
    }

    /// Every ask for `hash` that crossed any pipe, in the order the pipes were made.
    func asks(for hash: BlobHash) -> [LinkPipe.Ask] {
        pipes.flatMap { $0.asks.filter { $0.hash == hash.string } }
    }

    /// FILE_CHUNK bytes over every pipe.
    var chunkBytes: Int { pipes.reduce(0) { $0 + $1.chunkBytes } }
}
