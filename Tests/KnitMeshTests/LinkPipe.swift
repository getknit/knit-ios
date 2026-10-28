import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// One phone in a ``LinkPipe`` lab: an engine and its link manager on a ``FakeRadio`` that reports file writes, sharing one
/// kept-prefix store as ``Mesh`` makes them, and driven the way ``Mesh`` drives them, synchronously. Synchronous rather
/// than through the actor: a lab of three phones is then one deterministic loop on one manual clock, with no timer
/// tasks to race the steps.
final class PipeNode {
    let peer: TestPeer
    let radio = FakeRadio(advertisesServiceData: false, reportsFileWrites: true)
    let stores: MeshStores
    let log = RecordingLog()
    let partials: MemoryPartialBlobStore
    let links: LinkManager
    let engine: MeshEngine

    init(_ peer: TestPeer, clock: ManualClock, seed: UInt64, custodyLimits: CustodyLimits = CustodyLimits()) {
        self.peer = peer
        stores = MeshStores.inMemory(custodyLimits: custodyLimits)
        let recording = log
        partials = MemoryPartialBlobStore { line in recording.log(.info, line) }
        links = LinkManager(
            localId: peer.nodeId,
            radio: radio,
            clock: clock,
            random: SeededGenerator(seed: seed),
            log: log,
            partials: partials
        )
        engine = MeshEngine(
            identity: peer.keys,
            prekeys: nil,
            deviceTag: nil,
            stores: stores,
            transport: links,
            clock: clock,
            random: SeededGenerator(seed: seed + 100),
            configuration: MeshConfiguration(queriesBlobHolders: true),
            log: log,
            ratchetEngine: RatchetEngine(),
            groupRatchetEngine: GroupRatchetEngine(),
            partials: partials
        )
    }

    var nodeId: NodeId { peer.nodeId }

    func start() {
        engine.start()
        links.start()
    }

    /// Hands the link manager's events to the engine in order, then the feeds' edge, as ``Mesh`` settles.
    func apply(_ events: [LinkManager.Event]) {
        for event in events {
            switch event {
            case .up(let neighbor):
                engine.linkUp(neighbor)
            case .down(let nodeId):
                engine.linkDown(nodeId)
            case .frame(let frame):
                engine.receive(frame)
            case .digest(let ids, let from):
                engine.receiveDigest(ids, from: from)
            case .file(let file):
                engine.receiveFile(file)
            case .fileProgress(let progress):
                engine.fileProgress(progress)
            case .fileSent(let hash, let peer):
                engine.fileSent(hash, to: peer)
            }
        }
        if links.takeFeedsChanged() {
            engine.fileFeedsChanged()
        }
    }

    /// Hands `bytes` read on `channel` to the link manager, then reports them processed to the radio, as ``Mesh`` does.
    func receive(_ bytes: [UInt8], on channel: ChannelID) {
        apply(links.handle(.received(channel, bytes)))
        radio.consumed(bytes.count, on: channel)
    }

    func fireDueTimers() {
        apply(links.advance())
        engine.advance()
        apply([])
    }

    /// Holds `bytes` as the blob they hash to.
    func hold(_ bytes: [UInt8]) {
        stores.blobs.insert(bytes, hash: BlobHash(of: bytes), mime: "image/jpeg", storedAt: EngineFixture.start)
    }
}

/// One link between two ``PipeNode``s: the bytes each radio writes are read back as records and handed to the other, record
/// by record, with the radio's report of each FILE record as it crosses. It records what it carried, and can be cut after
/// some bytes of a file, as a link at the edge of range is: both channels close, and each side's teardown keeps what it
/// had (`LinkManager.retire`). One channel each side for the pipe's life, so one intake, and the #161 window, per link.
final class LinkPipe {
    /// A file header that crossed, holder to asker, and when.
    struct Serve: Equatable {
        var from: NodeId
        var to: NodeId
        var hash: BlobHash
        var offset: Int?
        var at: Int64
    }

    /// A `blobreq` that crossed, and when.
    struct Ask: Equatable {
        var from: NodeId
        var to: NodeId
        var hash: String
        var offset: Int64?
        var at: Int64
    }

    /// A FRAME record that crossed, and when.
    struct Frame: Equatable {
        var from: NodeId
        var to: NodeId
        var id: String
        var type: FrameType
        /// The record's payload: the encoded `WireEnvelope`.
        var bytes: Int
        var at: Int64
    }

    /// A record read off a radio under ``delay``, its encoded size, and when it may cross.
    private struct InFlight {
        var record: LinkRecord
        var bytes: Int
        var due: Int64
    }

    private struct Side {
        let node: PipeNode
        let channel: ChannelID
        var read = 0
        var reader = LinkRecordReader()
        // While the side's writes are out but unread (``LinkPipe/unread``): how far they were parsed, and how many FILE
        // records each way of reporting has reported, so a record is reported written once, whichever reports it first.
        var aired = 0
        var airReader = LinkRecordReader()
        var airedFileRecords = 0
        var deliveredFileRecords = 0
        // Records read off the side's radio that have not crossed yet, under ``LinkPipe/delay``, each with when it may.
        var inFlight: [InFlight] = []
    }

    private var sides: [Side]
    private let clock: ManualClock
    /// When set, the pipe is cut once this many bytes of FILE_CHUNK have crossed it, either way.
    var cutAfter: Int?
    private(set) var isUp = true
    /// The FILE_CHUNK bytes it carried, either way.
    private(set) var chunkBytes = 0
    private(set) var serves: [Serve] = []
    private(set) var asks: [Ask] = []
    /// Every FRAME record it carried, either way, its envelope decoded.
    private(set) var frames: [Frame] = []
    /// When set, what this node writes waits on its radio, unread, as on a link whose air is slow: nothing it writes
    /// crosses, and no FILE record it writes is reported written, until this is cleared.
    var holding: PipeNode?
    /// When set, what this node writes leaves its radio but the far side never reads it, as on a link whose reader
    /// stalled: each FILE record is reported written at once, and nothing crosses until this is cleared. So a feed runs
    /// on into the air where ``holding`` stops it after one chunk.
    var unread: PipeNode?
    /// When set, what the node writes crosses this many ms after the pipe first sees it, each FILE record reported written
    /// at once, as on a link whose round trip is long: a feed's window grows to cover it. ``unread`` then stops even what
    /// is under way.
    var delay: (node: PipeNode, milliseconds: Int64)?

    /// Links `dialer` and `answerer` on `channel`, each side its own channel number: the answerer accepts and reads the
    /// dialer's HELLO, and its answer, piped back, admits the dialer. The dialer's own written HELLO is a stray it ignores.
    init(_ dialer: PipeNode, _ answerer: PipeNode, channel: UInt64, clock: ManualClock) {
        self.clock = clock
        sides = [Side(node: dialer, channel: ChannelID(channel)), Side(node: answerer, channel: ChannelID(channel + 1))]
        dialer.apply(dialer.links.handle(.accepted(ChannelID(channel))))
        answerer.apply(answerer.links.handle(.accepted(ChannelID(channel + 1))))
        let hello = Hello(nodeId: dialer.nodeId.string, capabilities: Capabilities.local.union(.blobHave)).payload
        answerer.receive(LinkRecord(.hello, payload: hello).encoded ?? [], on: ChannelID(channel + 1))
    }

    /// Carries what is waiting either way, once. Answers whether anything crossed.
    func pumpOnce() -> Bool {
        guard isUp else {
            return false
        }
        var moved = false
        let now = clock.monotonicMilliseconds()
        for index in sides.indices where sides[index].node !== holding {
            let writes = sides[index].node.radio.writes(on: sides[index].channel)
            let delayed = delay.flatMap { $0.node === sides[index].node ? $0.milliseconds : nil }
            if sides[index].node === unread || delayed != nil {
                moved = air(writes, from: index) || moved
            }
            if sides[index].node === unread {
                continue
            }
            if sides[index].read < writes.count {
                for write in writes[sides[index].read...] {
                    sides[index].reader.append(write[...])
                }
                sides[index].read = writes.count
            }
            while isUp, let record = try? sides[index].reader.next() {
                if let delayed {
                    sides[index].inFlight.append(InFlight(record: record, bytes: record.encoded?.count ?? 0, due: now + delayed))
                } else {
                    moved = true
                    deliver(record, from: index)
                }
            }
            while isUp, let first = sides[index].inFlight.first, first.due <= now {
                sides[index].inFlight.removeFirst()
                moved = true
                deliver(first.record, from: index)
            }
        }
        return moved
    }

    private func deliver(_ record: LinkRecord, from index: Int) {
        let sender = sides[index]
        let receiver = sides[1 - index]
        let now = clock.monotonicMilliseconds()
        if record.tag == .fileHeader, let header = LinkJSON.fileHeader(from: record.payload), let hash = BlobHash(header.key) {
            serves.append(Serve(from: sender.node.nodeId, to: receiver.node.nodeId, hash: hash, offset: header.offset, at: now))
        }
        if record.tag == .frame, let crossed = Self.frame(record, from: sender.node, to: receiver.node, at: now) {
            frames.append(crossed)
        }
        if record.tag == .frame, let ask = Self.ask(in: record.payload) {
            asks.append(Ask(from: sender.node.nodeId, to: receiver.node.nodeId, hash: ask.hash, offset: ask.offset, at: now))
        }
        receiver.node.receive(record.encoded ?? [], on: receiver.channel)
        guard [.fileHeader, .fileChunk, .fileEnd].contains(record.tag) else {
            return
        }
        sides[index].deliveredFileRecords += 1
        if sides[index].deliveredFileRecords > sides[index].airedFileRecords {
            sender.node.apply(sender.node.links.handle(.wroteFileRecord(sender.channel)))
        }
        if record.tag == .fileChunk {
            chunkBytes += record.payload.count
            if let cutAfter, chunkBytes >= cutAfter {
                cut()
            }
        }
    }

    /// Reports each FILE record among the side's new `writes` written, delivering nothing. Answers whether any was.
    private func air(_ writes: [[UInt8]], from index: Int) -> Bool {
        guard sides[index].aired < writes.count else {
            return false
        }
        for write in writes[sides[index].aired...] {
            sides[index].airReader.append(write[...])
        }
        sides[index].aired = writes.count
        var reported = false
        while let record = try? sides[index].airReader.next() {
            guard [.fileHeader, .fileChunk, .fileEnd].contains(record.tag) else {
                continue
            }
            sides[index].airedFileRecords += 1
            if sides[index].airedFileRecords > sides[index].deliveredFileRecords {
                reported = true
                sides[index].node.apply(sides[index].node.links.handle(.wroteFileRecord(sides[index].channel)))
            }
        }
        return reported
    }

    /// Hands `record` to the far side of `node` as if `node` had written it, recorded as anything that crossed is: a
    /// peer that writes what its engine never would.
    func inject(_ record: LinkRecord, from node: PipeNode) {
        guard isUp, let index = sides.firstIndex(where: { $0.node === node }) else {
            return
        }
        deliver(record, from: index)
    }

    /// The bytes `node` wrote that have not crossed yet.
    func undelivered(from node: PipeNode) -> Int {
        guard let side = sides.first(where: { $0.node === node }) else {
            return 0
        }
        return side.node.radio.writes(on: side.channel).dropFirst(side.read).reduce(0) { $0 + $1.count }
            + side.inFlight.reduce(0) { $0 + $1.bytes }
    }

    /// The channel `node` reads this pipe on.
    func channel(of node: PipeNode) -> ChannelID? {
        sides.first { $0.node === node }?.channel
    }

    /// The frame a FRAME record carries, as it crossed from `sender` to `receiver`, if its envelope decodes.
    private static func frame(_ record: LinkRecord, from sender: PipeNode, to receiver: PipeNode, at now: Int64) -> Frame? {
        guard let wire = try? WireEnvelope(decoding: record.payload), let envelope = try? RelayEnvelope(decoding: wire.signed) else {
            return nil
        }
        return Frame(from: sender.nodeId, to: receiver.nodeId, id: envelope.id, type: envelope.type, bytes: record.payload.count, at: now)
    }

    /// The `blobreq` a FRAME record carries, if it is one.
    private static func ask(in payload: [UInt8]) -> BlobRequestContent? {
        guard let wire = try? WireEnvelope(decoding: payload), let envelope = try? RelayEnvelope(decoding: wire.signed),
            envelope.type == .blobRequest
        else {
            return nil
        }
        return try? BlobRequestContent(decoding: envelope.payload)
    }

    /// Closes both ends, as a link that dies does.
    func cut() {
        guard isUp else {
            return
        }
        isUp = false
        for side in sides {
            side.node.apply(side.node.links.handle(.closed(side.channel)))
        }
    }
}

/// The phones and their pipes on one manual clock.
final class PipeLab {
    let clock = ManualClock(wall: EngineFixture.start, monotonic: 1000)
    private(set) var pipes: [LinkPipe] = []
    private var nodes: [PipeNode] = []
    private var nextChannel: UInt64 = 10

    /// A started phone for `seed`, its custody under `custodyLimits`.
    func node(_ seed: Int, custodyLimits: CustodyLimits = CustodyLimits()) -> PipeNode {
        let node = PipeNode(TestPeer(seed: seed), clock: clock, seed: UInt64(seed), custodyLimits: custodyLimits)
        node.start()
        nodes.append(node)
        return node
    }

    @discardableResult
    func link(_ dialer: PipeNode, _ answerer: PipeNode, cutAfter: Int? = nil, holding: PipeNode? = nil) -> LinkPipe {
        let pipe = LinkPipe(dialer, answerer, channel: nextChannel, clock: clock)
        pipe.cutAfter = cutAfter
        pipe.holding = holding
        nextChannel += 2
        pipes.append(pipe)
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
