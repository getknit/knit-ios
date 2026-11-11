import Foundation
import KnitCrypto
import KnitMesh
import KnitPeer
import KnitStore
import KnitSync
import KnitTestSupport
import KnitWire
import Testing

/// Clocks that stand still. A sleeper waits until it is cancelled, so no timer ever fires in these tests.
final class StillClock: MeshClock {
    static let wall: Int64 = 1_790_300_000_000

    func wallMilliseconds() -> Int64 {
        Self.wall
    }

    func monotonicMilliseconds() -> Int64 {
        1000
    }

    func sleep(untilMonotonic _: Int64) async throws {
        try await Task.sleep(for: .seconds(3600))
    }
}

/// A radio that records what it is asked, and reports what the test emits.
final class PeerRadio: Radio {
    let advertisesServiceData = true
    let dialsGattPeers = false
    let servesDoorbell = false
    let events: AsyncStream<RadioEvent>
    private let emitter: AsyncStream<RadioEvent>.Continuation
    private struct State {
        var started = false
        var stopped = false
        var writes: [ChannelID: [UInt8]] = [:]
        var closed: [ChannelID] = []
        var consumed: [ChannelID: Int] = [:]
        var queued: [ChannelID: Int] = [:]
    }

    private let state = Lock(State())

    init() {
        (events, emitter) = AsyncStream<RadioEvent>.makeStream()
    }

    var started: Bool { state.withLock { $0.started } }
    var stopped: Bool { state.withLock { $0.stopped } }
    var closed: [ChannelID] { state.withLock { $0.closed } }

    /// The bytes reported processed on `channel` (``Radio/consumed(_:on:)``).
    func consumed(on channel: ChannelID) -> Int {
        state.withLock { $0.consumed[channel, default: 0] }
    }

    func consumed(_ count: Int, on channel: ChannelID) {
        state.withLock { $0.consumed[channel, default: 0] += count }
    }

    /// Says `bytes` wait unwritten on `channel`, as a real radio's queue would.
    func setQueued(_ bytes: Int, on channel: ChannelID) {
        state.withLock { $0.queued[channel] = bytes }
    }

    func outboxLevel(on channel: ChannelID) -> OutboxLevel {
        OutboxLevel(queuedBytes: state.withLock { $0.queued[channel, default: 0] })
    }

    func emit(_ event: RadioEvent) {
        emitter.yield(event)
    }

    func start() {
        state.withLock { $0.started = true }
    }

    func stop() {
        state.withLock { $0.stopped = true }
    }

    func advertise(_: AdvertPayload) {
        // Nothing reads the advert in these tests.
    }

    func dial(_: RadioAddress, psm _: UInt16) -> ChannelID {
        ChannelID(999)
    }

    func write(_ bytes: [UInt8], to channel: ChannelID) {
        state.withLock { $0.writes[channel, default: []] += bytes }
    }

    func close(_ channel: ChannelID) {
        state.withLock { $0.closed.append(channel) }
    }

    /// Every record written on `channel`, parsed back.
    func records(on channel: ChannelID) -> [LinkRecord] {
        var reader = LinkRecordReader()
        reader.append(state.withLock { $0.writes[channel, default: []] })
        var records: [LinkRecord] = []
        while let record = try? reader.next() {
            records.append(record)
        }
        return records
    }

    /// The frames written on `channel`, decoded.
    func frames(on channel: ChannelID) -> [WireEnvelope] {
        var reader = LinkRecordReader()
        reader.append(state.withLock { $0.writes[channel, default: []] })
        var frames: [WireEnvelope] = []
        while let record = try? reader.next() {
            if record.tag == .frame, let wire = try? WireEnvelope(decoding: record.payload) {
                frames.append(wire)
            }
        }
        return frames
    }
}

/// A transport that says `peer` is linked and keeps what the engine sends it.
final class CapturingTransport: MeshTransport {
    let peer: NodeId
    private(set) var sent: [WireEnvelope] = []

    init(peer: NodeId) {
        self.peer = peer
    }

    var neighbors: [Neighbor] { [Neighbor(nodeId: peer, capabilities: 0xFFF)] }

    func send(_ wire: WireEnvelope, to _: NodeId?) {
        sent.append(wire)
    }

    func sendDigest(_: [String], to _: NodeId) {
        // The peer under test learns nothing from the far side's digest here.
    }

    func queuedBytes(to _: NodeId) -> Int {
        // The far side takes every write at once.
        0
    }

    func hasCrossed(_: String, to _: NodeId) -> Bool {
        // Nothing here remembers what crossed.
        false
    }

    func sendFile(_: OutboundFile, to _: NodeId) -> Bool {
        // The far side here takes frames only.
        false
    }

    func isFileInFlight(_: BlobHash, to _: NodeId) -> Bool {
        false
    }

    func cancelQueuedFile(_: BlobHash, to _: NodeId) -> Bool {
        // Nothing is ever queued here.
        false
    }

    var arrivingFileKeys: Set<BlobHash> { [] }

    var feedingLoad: Int { 0 }

    func acceptFiles(_: Set<BlobHash>, resumable _: Set<BlobHash>, photoOnly _: Set<BlobHash>) {
        // Nothing streams in here.
    }

    func filesWaiting(to _: NodeId) -> Int {
        // Nothing streams out here.
        0
    }

    func peerProvesItself(_: NodeId) {
        // No link here to close.
    }

    func listPresenceKeys(_: [NodeId: [PresenceKey]]) {
        // No radio here to resolve a tag.
    }

    func sendOverProvenLink(_ wire: WireEnvelope, to peer: NodeId) -> Bool {
        // The one link here proved its id.
        send(wire, to: peer)
        return true
    }

    func hasProvenLink(to peer: NodeId) -> Bool {
        peer == self.peer
    }

    func fileTaken(from _: NodeId, hash _: BlobHash) {
        // Nothing streams in here.
    }

    func fileProgressReported(from _: NodeId, hash _: BlobHash, held _: Int64, milliseconds _: Int64) {
        // Nothing streams out here, so no report has a window to clock.
    }

    func isFileArriving(from _: NodeId) -> Bool {
        false
    }

    func fileArrivingLeftMilliseconds(from _: NodeId) -> Int64? {
        nil
    }

    func fileFeed(of _: BlobHash, to _: NodeId) -> FeedReading? {
        // Nothing streams out here, so nothing is fed.
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

/// Collects the lines a node writes, so a test can wait for one.
final class LineCollector: Sendable {
    private let lines = Lock<[String]>([])

    var all: [String] { lines.withLock { $0 } }

    @Sendable
    func write(_ line: String) {
        lines.withLock { $0.append(line) }
    }

    /// The lines as JSON objects.
    var objects: [[String: Any]] {
        all.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    /// Waits, yielding, until a line matches, for at most five seconds. A count of turns is no budget: under
    /// coverage instrumentation on a busy machine, five thousand of them ran out before the node wrote its line.
    func first(where match: ([String: Any]) -> Bool) async -> [String: Any]? {
        await nth(1, where: match)
    }

    /// Waits as ``first(where:)`` does, until `count` lines match, and answers the last of them.
    func nth(_ count: Int, where match: ([String: Any]) -> Bool) async -> [String: Any]? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let matching = objects.filter(match)
            if matching.count >= count {
                return matching[count - 1]
            }
            await Task.yield()
        }
        return nil
    }
}

/// Keys from fixed seeds.
func identity(_ seed: Int) -> IdentityKeys {
    guard let keys = IdentityKeys(signingSeed: fixtureBytes(32, seed: seed), agreementScalar: fixtureBytes(32, seed: seed + 100)) else {
        fatalError("fixed seeds make valid keys")
    }
    return keys
}

/// A deterministic generator.
struct CountingGenerator: RandomNumberGenerator, Sendable {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

/// A link record's bytes.
func record(_ tag: LinkRecord.Tag, _ payload: [UInt8]) -> [UInt8] {
    LinkRecord(tag, payload: payload).encoded ?? []
}

/// Plays the dialer of a link on `channel` of a node that accepts it, proving `keys`'s id as an upgraded build does (the
/// `link-hello-proof` contract, §5): our HELLO with the bit and a fresh nonce, then, once the node's reply and PROOF are
/// written, our own PROOF over both HELLOs. `deliver` hands the node a radio event, and `written` reads back the records it
/// wrote on the channel, those written before the dial included. The node then registers the link as proven.
func dialProving(
    as keys: IdentityKeys, on channel: ChannelID, deliver: (RadioEvent) async -> Void, written: () -> [LinkRecord]
) async throws {
    let before = written().count
    let hello = Hello(nodeId: keys.nodeId.string, capabilities: Capabilities.local.union(.blobHave), nonce: LinkProof.freshNonce())
    await deliver(.accepted(channel))
    await deliver(.received(channel, record(.hello, hello.payload)))
    let answered = await waitUntil {
        let tags = written().dropFirst(before).map(\.tag)
        return tags.contains(.hello) && tags.contains(.proof)
    }
    try #require(answered, "the node answered with its HELLO and its PROOF")
    let reply = try #require(written().dropFirst(before).first { $0.tag == .hello })
    let proof = try LinkProof.payload(keys: keys, signer: .dialer, dialerHello: hello.payload, responderHello: reply.payload)
    await deliver(.received(channel, record(.proof, proof)))
}

/// A node under test on a ``PeerRadio``, and a second engine that plays the far end of one link.
struct PeerRig {
    static let channel = ChannelID(7)

    let keys = identity(1)
    let far = identity(2)
    let radio = PeerRadio()
    let lines = LineCollector()
    let stores: MeshStores
    let node: PeerNode
    let farTransport: CapturingTransport
    let farEngine: MeshEngine

    /// A peer on fresh stores in memory, its own profile in `ownProfile` when given, keeping its photo at `avatarPath`
    /// when given: a restart is a second rig on the same two. `ratchet` and `prekeys` are `--ratchet`'s switch and the ring
    /// its `main` loads.
    init(
        ownProfile: (any OwnProfileStore & Checkpointing)? = nil, avatarPath: String? = nil, ratchet: Bool = false,
        prekeys: PrekeyRing? = nil
    ) {
        let made = ownProfile.map { MeshStores.inMemory(ownProfileStore: $0) } ?? .inMemory()
        stores = made
        node = PeerNode(
            identity: keys,
            prekeys: prekeys,
            ratchet: ratchet,
            stores: made,
            radio: radio,
            radioProfile: "android",
            clock: StillClock(),
            random: CountingGenerator(),
            log: SilentLog(),
            avatarPath: avatarPath,
            output: lines.write
        )
        farTransport = CapturingTransport(peer: keys.nodeId)
        farEngine = MeshEngine(
            identity: far,
            deviceTag: nil,
            stores: .inMemory(ownProfile: OwnProfile(name: "Far")),
            transport: farTransport,
            clock: StillClock(),
            random: CountingGenerator()
        )
    }

    /// Sends `line` and answers the reply as a JSON object.
    @discardableResult
    func send(_ line: String) async throws -> [String: Any] {
        let before = lines.all.count
        await node.handle(line)
        let reply = lines.all.dropFirst(before).compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
            .first { $0["reply"] != nil }
        return try #require(reply)
    }

    /// Links the far node as a dialer we never sighted, proving its id as an upgraded build's would, and waits for the link
    /// event: the `count`th, for a link made again.
    func link(count: Int = 1) async throws {
        try await dialProving(as: far, on: Self.channel, deliver: { radio.emit($0) }, written: { radio.records(on: Self.channel) })
        _ = try #require(await lines.nth(count) { $0["event"] as? String == "link" && $0["up"] as? Bool == true })
    }

    /// A whole file as the far peer would stream it: its header, one chunk and its END.
    func fileRecords(_ kind: FileHeader.Kind, _ bytes: [UInt8]) -> [UInt8] {
        record(.fileHeader, LinkJSON.fileHeaderPayload(FileHeader(kind: kind, key: BlobHash(of: bytes).string, mime: "image/jpeg")))
            + record(.fileChunk, bytes) + record(.fileEnd, [])
    }

    /// Hands every frame the far engine sent to the node, as if over the link.
    func deliverFromFar() {
        for wire in farTransport.take() {
            // The far engine mints only canonical ids; one the node's router refused unnoticed would hide a regression.
            #expect((try? RelayEnvelope(decoding: wire.signed)).map(FrameId.admits) ?? false, "the far engine's frame passes the id gate")
            radio.emit(.received(Self.channel, record(.frame, wire.encoded)))
        }
    }

    /// Hands every frame the node wrote to the far engine.
    func deliverToFar() {
        for wire in radio.frames(on: Self.channel) {
            guard let envelope = try? RelayEnvelope(decoding: wire.signed) else {
                continue
            }
            // The node mints only canonical ids; a frame the far router refused unnoticed would hide a regression.
            #expect(FrameId.admits(envelope), "\(envelope.type.rawValue) \(envelope.id) is not its type's id shape")
            farEngine.receive(InboundFrame(wire: wire, envelope: envelope, from: keys.nodeId))
        }
    }
}
