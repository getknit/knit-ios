import KnitCrypto
import KnitMesh
import KnitPeer
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// An engine over knit-peer's lying blob store answers a holder query and an ask as the switches say: the junk's size and
/// the junk itself under the hash, or, for a blob withheld, not held and nothing served.
@Suite(.timeLimit(.minutes(1))) struct LyingBlobEngineTests {
    private let asker = identity(2)
    private let photo = fixtureBytes(30_000, seed: 4)
    private var hash: BlobHash { BlobHash(of: photo) }

    /// An engine over the liar, the store it lies through and its transport.
    private struct Liar {
        let engine: MeshEngine
        let lying: LyingBlobStore
        let transport: ServingTransport
    }

    /// An engine over the liar, `asker` linked to it, holding ``photo``.
    private func makeLiar() -> Liar {
        let (stores, lying) = LyingBlobStore.stores(over: .inMemory(ownProfile: OwnProfile(name: "Liar")))
        stores.blobs.insert(photo, hash: hash, mime: "image/jpeg", storedAt: StillClock.wall)
        let transport = ServingTransport(peer: asker.nodeId)
        let engine = MeshEngine(
            identity: identity(1), deviceTag: nil, stores: stores, transport: transport, clock: StillClock(), random: CountingGenerator())
        return Liar(engine: engine, lying: lying, transport: transport)
    }

    /// `content` from the asker, unsigned and point to point, as its engine sends a query or an ask.
    private func fromAsker(_ type: FrameType, _ content: [UInt8], id seed: UInt64) -> InboundFrame {
        var random = CountingGenerator(state: seed)
        let envelope = RelayEnvelope(type: type, id: FrameId.generate(using: &random), senderId: asker.nodeId.string, payload: content)
        return InboundFrame(wire: WireEnvelope(relay: false, sig: [], signed: envelope.encoded), envelope: envelope, from: asker.nodeId)
    }

    private func query(_ engine: MeshEngine, _ transport: ServingTransport, seed: UInt64) throws -> BlobHasItem {
        engine.receive(fromAsker(.blobHave, BlobHaveContent(hashes: [hash.string]).encoded, id: seed))
        let answers = try transport.take().compactMap { wire -> BlobHasContent? in
            let envelope = try RelayEnvelope(decoding: wire.signed)
            return envelope.type == .blobHas ? try BlobHasContent(decoding: envelope.payload) : nil
        }
        return try #require(only(answers).flatMap { only($0.items) })
    }

    @Test func junkIsAnsweredAtItsSizeAndServedWholeUnderTheHash() throws {
        let liar = makeLiar()
        let engine = liar.engine
        let lying = liar.lying
        let transport = liar.transport
        let junkBytes = 1_048_576 + 65_536
        try lying.setJunk(hash, bytes: junkBytes)

        let item = try query(engine, transport, seed: 11)
        #expect(item == BlobHasItem(hash: hash.string, state: .have, size: Int64(junkBytes)))

        engine.receive(fromAsker(.blobRequest, BlobRequestContent(hash: hash.string, pull: 0).encoded, id: 12))
        let file = try #require(only(transport.files))
        #expect(file.hash == hash && file.kind == .attachment && file.size == junkBytes && file.start == 0)
        var streamed: [UInt8] = []
        while streamed.count < file.size, let chunk = file.read(streamed.count, 65_536), !chunk.isEmpty {
            streamed += chunk
        }
        #expect(streamed.count == junkBytes && Array(streamed.prefix(photo.count)) != photo, "junk of the size set, not the photo")
        #expect(lying.junkBytesServed == Int64(junkBytes))
    }

    @Test func aWithheldBlobIsAnsweredNotHeldAndNeverServed() throws {
        let liar = makeLiar()
        let engine = liar.engine
        let lying = liar.lying
        let transport = liar.transport
        lying.withhold(hash)

        let item = try query(engine, transport, seed: 21)
        #expect(item == BlobHasItem(hash: hash.string, state: .notHeld))

        engine.receive(fromAsker(.blobRequest, BlobRequestContent(hash: hash.string, pull: 0).encoded, id: 22))
        #expect(transport.files.isEmpty)
        #expect(engine.stores.blobs.contains(hash), "still held, so never wanted")
        // A plain ask, the budget the trial's asker carries: held, so it neither serves nor wants, queries or asks.
        let sentBefore = transport.sent.count
        engine.receive(fromAsker(.blobRequest, BlobRequestContent(hash: hash.string, pull: 3).encoded, id: 24))
        let types = transport.sent.dropFirst(sentBefore).compactMap { try? RelayEnvelope(decoding: $0.signed).type }
        #expect(!types.contains(.blobHave) && !types.contains(.blobRequest), "sent \(types)")
        #expect(transport.files.isEmpty)

        lying.release(hash)
        #expect(try query(engine, transport, seed: 23) == BlobHasItem(hash: hash.string, state: .have, size: Int64(photo.count)))
    }

    @Test func withNothingSetTheHeldPhotoIsAnsweredAndServedAsItIs() throws {
        let liar = makeLiar()
        let engine = liar.engine
        let transport = liar.transport
        #expect(try query(engine, transport, seed: 31) == BlobHasItem(hash: hash.string, state: .have, size: Int64(photo.count)))
        engine.receive(fromAsker(.blobRequest, BlobRequestContent(hash: hash.string, pull: 0).encoded, id: 32))
        let file = try #require(only(transport.files))
        #expect(file.size == photo.count && file.read(0, photo.count) == photo)
    }
}

/// The one element of `elements`, or `nil` when there are none or more.
private func only<Element>(_ elements: [Element]) -> Element? {
    elements.count == 1 ? elements.first : nil
}

/// A transport that says `peer` is linked, keeps what the engine sends it, and takes every file it is asked to stream.
private final class ServingTransport: MeshTransport {
    let peer: NodeId
    private(set) var sent: [WireEnvelope] = []
    private(set) var files: [OutboundFile] = []

    init(peer: NodeId) {
        self.peer = peer
    }

    var neighbors: [Neighbor] { [Neighbor(nodeId: peer, capabilities: 0xFFF)] }

    func send(_ wire: WireEnvelope, to _: NodeId?) {
        sent.append(wire)
    }

    func sendDigest(_: [String], to _: NodeId) {
        // Nothing here reads a digest.
    }

    func queuedBytes(to _: NodeId) -> Int {
        0
    }

    func hasCrossed(_: String, to _: NodeId) -> Bool {
        false
    }

    func sendFile(_ file: OutboundFile, to _: NodeId) -> Bool {
        files.append(file)
        return true
    }

    func isFileInFlight(_: BlobHash, to _: NodeId) -> Bool {
        // Each test serves a hash once.
        false
    }

    func cancelQueuedFile(_: BlobHash, to _: NodeId) -> Bool {
        false
    }

    var arrivingFileKeys: Set<BlobHash> { [] }

    var feedingLoad: Int { 0 }

    func acceptFiles(_: Set<BlobHash>, resumable _: Set<BlobHash>, photoOnly _: Set<BlobHash>) {
        // Nothing streams in here.
    }

    func filesWaiting(to _: NodeId) -> Int {
        0
    }

    func fileTaken(from _: NodeId, hash _: BlobHash) {
        // Nothing streams in here.
    }

    func fileProgressReported(from _: NodeId, hash _: BlobHash, held _: Int64, milliseconds _: Int64) {
        // No feed here has a window to clock.
    }

    func isFileArriving(from _: NodeId) -> Bool {
        false
    }

    func fileArrivingLeftMilliseconds(from _: NodeId) -> Int64? {
        nil
    }

    func fileFeed(of _: BlobHash, to _: NodeId) -> FeedReading? {
        nil
    }

    func expectedFileRate(to _: NodeId) -> Int64 {
        0
    }

    /// Everything sent since the last call.
    func take() -> [WireEnvelope] {
        defer { sent.removeAll() }
        return sent
    }
}
