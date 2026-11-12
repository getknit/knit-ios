import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitCrypto
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

    /// A phone of `peer`'s. By default an engine with no ratchet; a lab that needs the ratchet gives its `configuration`, the
    /// `prekeys` it keeps and a `deviceTag`.
    init(
        _ peer: TestPeer,
        clock: ManualClock,
        seed: UInt64,
        custodyLimits: CustodyLimits = CustodyLimits(),
        configuration: MeshConfiguration = MeshConfiguration(queriesBlobHolders: true),
        prekeys: PrekeyRing? = nil,
        deviceTag: String? = nil
    ) {
        self.peer = peer
        stores = MeshStores.inMemory(custodyLimits: custodyLimits)
        let recording = log
        partials = MemoryPartialBlobStore { line in recording.log(.info, line) }
        links = LinkManager(
            identity: peer.keys,
            radio: radio,
            clock: clock,
            random: SeededGenerator(seed: seed),
            log: log,
            partials: partials
        )
        engine = MeshEngine(
            identity: peer.keys,
            prekeys: prekeys,
            deviceTag: deviceTag,
            stores: stores,
            transport: links,
            clock: clock,
            random: SeededGenerator(seed: seed + 100),
            configuration: configuration,
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
            case .fileOverLimit(let hash, let peer):
                engine.fileOverLimit(hash, from: peer)
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
