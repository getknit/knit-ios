import Foundation
import KnitCrypto
import KnitMesh
import KnitPeer
import KnitStore
import KnitSync
import KnitTestSupport
import KnitWire
import Testing

/// A knit-peer liar as `knit-peer run --lying` builds it, a ``PeerNode`` on ``PeerLyingParts`` over a ``PeerRadio``, and
/// an honest receiver, a ``Mesh`` on a ``PeerRadio`` of its own, linked by moving each side's records to the other: the
/// door-cap trial's two ends, with both link managers in the path (`door-cap-lying-peers`). Built without `lying`, the
/// node runs as `knit-peer run` does, unwrapped.
///
/// The link is made by playing the liar as the dialer of a channel the receiver accepted, then the receiver as the dialer
/// of one the liar accepted, each proving its id with its own keys (``dialProving(as:on:deliver:written:)``): each admits
/// the other as a dialer it never sighted, and takes the other's reply and PROOF, which follow on the pump, as the strays
/// they are on a live link. The liar's timers never fire (its monotonic clock stands still); the receiver's fire when a
/// test moves its clock and calls ``rewant()``.
final class LyingTrialRig {
    static let liarChannel = ChannelID(7)
    static let receiverChannel = ChannelID(8)
    /// A plausible size for a profile photo, and one over the 1 MiB ceiling.
    static let plausible: Int64 = 30_000
    static let overCeiling: Int64 = 2_097_152
    /// The junk the trial streams: past the ceiling, and long enough that a tail runs on after it.
    static let junkBytes = 1_048_576 + 65_536

    let keys = identity(1)
    let receiverKeys = identity(2)
    let directory: String
    let liarClock = SteppingClock()
    let receiverClock = HandClock()
    let inner = PeerRadio()
    let parts: PeerLyingParts?
    let stores: MeshStores
    let lines = LineCollector()
    let node: PeerNode
    let receiverRadio = PeerRadio()
    let receiverStores = MeshStores.inMemory(ownProfile: OwnProfile(name: "Receiver"))
    let receiver: Mesh
    private let handed = Lock((toReceiver: 0, toLiar: 0))
    private let dropped = Lock<Set<FrameType>>([])

    /// A liar over `directory`, a fresh one unless given; one given is a restart, which keeps the profile there. The node
    /// logs to `log`.
    init(lying: Bool = true, directory: String? = nil, log: any KnitLog = SilentLog()) throws {
        self.directory = directory ?? temporaryStateDirectory()
        let state = PeerState(directory: self.directory)
        if directory == nil {
            try state.replaceIdentity(with: keys)
        }
        let radio: any Radio
        if lying {
            let wrapped = PeerLyingParts.wrapping(
                inner,
                profileStore: state.profileStore(),
                localId: keys.nodeId,
                stateDirectory: self.directory,
                random: CountingGenerator(state: 0x1717)
            )
            (parts, stores, radio) = (wrapped.parts, wrapped.stores, wrapped.parts.radio)
        } else {
            (parts, stores, radio) = (nil, MeshStores.inMemory(ownProfileStore: state.profileStore()), inner)
        }
        node = PeerNode(
            identity: keys,
            stores: stores,
            radio: radio,
            radioProfile: "android",
            clock: liarClock,
            random: CountingGenerator(),
            log: log,
            stateDirectory: self.directory,
            lying: parts,
            output: lines.write
        )
        receiver = Mesh(
            identity: receiverKeys,
            deviceTag: nil,
            stores: receiverStores,
            radio: receiverRadio,
            clock: receiverClock,
            random: CountingGenerator(state: 0x5151_5151_5151_5151),
            configuration: MeshConfiguration(queriesBlobHolders: true, ratchet: false)
        )
    }

    var markerPath: String { directory + "/" + ProfileLies.markerName }

    func remove() {
        try? FileManager.default.removeItem(atPath: directory)
    }

    /// Starts both ends and the liar under `name`.
    func start(name: String = "Liar") async {
        await receiver.start()
        await node.start(name: name)
    }

    /// Links the two ends and waits until each has the other as a neighbour.
    func link() async throws {
        let (mesh, meshRadio, liarRadio) = (receiver, receiverRadio, inner)
        try await dialProving(
            as: keys,
            on: Self.receiverChannel,
            deliver: { event in await mesh.process(event) },
            written: { meshRadio.records(on: Self.receiverChannel) }
        )
        try await dialProving(
            as: receiverKeys,
            on: Self.liarChannel,
            deliver: { event in liarRadio.emit(event) },
            written: { liarRadio.records(on: Self.liarChannel) }
        )
        // The liar hears its radio on its own task: nothing crosses to it before its proof has verified.
        let liarLinked = await waitUntil { self.lines.objects.contains { $0["event"] as? String == "link" && $0["up"] as? Bool == true } }
        try #require(liarLinked, "the liar registered the receiver")
        let linked = await exchange {
            let theirs = await self.receiver.neighbors.contains { $0.nodeId == self.keys.nodeId }
            return theirs && self.lines.objects.contains { $0["event"] as? String == "link" && $0["up"] as? Bool == true }
        }
        try #require(linked, "the two ends linked")
    }

    /// Sends `line` to the liar and answers its reply.
    @discardableResult
    func send(_ line: String) async throws -> [String: Any] {
        let before = lines.all.count
        await node.handle(line)
        let reply = lines.all.dropFirst(before).compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
            .first { $0["reply"] != nil }
        return try #require(reply)
    }

    /// `status`'s `lying`.
    func lying() async throws -> [String: Any] {
        try #require(try await send(#"{"cmd":"status"}"#)["lying"] as? [String: Any])
    }

    /// The liar's frames of `type` the receiver's link no longer carries to it: a test stands in for what they would set
    /// off.
    func drop(_ type: FrameType) {
        dropped.withLock { _ = $0.insert(type) }
    }

    // MARK: Moving records

    /// Moves every whole record written since the last call to the other end.
    func pump() async {
        let toReceiver = inner.records(on: Self.liarChannel)
        let fresh = handed.withLock { counts in
            defer { counts.toReceiver = toReceiver.count }
            return toReceiver.dropFirst(counts.toReceiver)
        }
        for record in fresh {
            await receiver.process(.received(Self.receiverChannel, record.encoded ?? []))
        }
        let toLiar = receiverRadio.records(on: Self.receiverChannel)
        let back = handed.withLock { counts in
            defer { counts.toLiar = toLiar.count }
            return toLiar.dropFirst(counts.toLiar)
        }
        let skipped = dropped.withLock { $0 }
        for record in back where !Self.isFrame(record, oneOf: skipped) {
            inner.emit(.received(Self.liarChannel, record.encoded ?? []))
        }
    }

    /// Moves records both ways until `done` holds, for at most five seconds.
    @discardableResult
    func exchange(until done: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            await pump()
            await receiver.fireDueTimers()
            if await done() {
                return true
            }
            await Task.yield()
        }
        return false
    }

    /// Moves records both ways for `rounds` turns, for whatever follows with nothing to wait on.
    func settle(rounds: Int = 200) async {
        for _ in 0..<rounds {
            await pump()
            await Task.yield()
        }
    }

    /// A minute on both clocks, the receiver's due timers fired: its next re-want of a blob not yet held.
    func rewant() async {
        receiverClock.advance(60_000)
        liarClock.advance(by: 60_000)
        await receiver.fireDueTimers()
        await settle()
        await receiver.fireDueTimers()
        await settle()
    }

    // MARK: What each end wrote

    /// The receiver's frames to the liar.
    var receiverFrames: [RelayEnvelope] {
        receiverRadio.frames(on: Self.receiverChannel).compactMap { try? RelayEnvelope(decoding: $0.signed) }
    }

    /// The receiver's holder queries and asks naming `hash`, all of them sent to the liar, its one link.
    func receiverAsks(for hash: BlobHash) -> (queries: Int, asks: Int) {
        let frames = receiverFrames
        let queries = frames.filter { frame in
            frame.type == .blobHave && ((try? BlobHaveContent(decoding: frame.payload))?.hashes.contains(hash.string) ?? false)
        }
        let asks = frames.filter { frame in
            frame.type == .blobRequest && (try? BlobRequestContent(decoding: frame.payload))?.hash == hash.string
        }
        return (queries.count, asks.count)
    }

    /// The liar's records on its link.
    var liarRecords: [LinkRecord] { inner.records(on: Self.liarChannel) }

    /// The liar's frames on its link.
    var liarFrames: [(wire: WireEnvelope, envelope: RelayEnvelope)] {
        inner.frames(on: Self.liarChannel).compactMap { wire in (try? RelayEnvelope(decoding: wire.signed)).map { (wire, $0) } }
    }

    /// Hands the receiver `wire` on the liar's link, as a frame the liar carried.
    func carry(_ wire: WireEnvelope) async {
        await receiver.process(.received(Self.receiverChannel, record(.frame, wire.encoded)))
    }

    /// The profile of a third node, not linked to either end, naming `photo` as its photo: the receiver's want for it is
    /// a photo-only want, as for the trial's peer B.
    static func profile(naming photo: [UInt8], seed: Int = 3) throws -> WireEnvelope {
        let transport = CapturingTransport(peer: identity(seed + 10).nodeId)
        let owner = MeshEngine(
            identity: identity(seed),
            deviceTag: nil,
            stores: .inMemory(ownProfile: OwnProfile(name: "Bea")),
            transport: transport,
            clock: StillClock(),
            random: CountingGenerator(state: UInt64(seed))
        )
        owner.start()
        owner.setAvatar(photo)
        let profiles = transport.sent.filter { wire in (try? RelayEnvelope(decoding: wire.signed))?.type == .profile }
        let named = BlobHash(of: photo).string
        return try #require(
            profiles.last { wire in
                (try? RelayEnvelope(decoding: wire.signed)).flatMap { try? ProfileContent(decoding: $0.payload) }?.avatarHash == named
            })
    }

    private static func isFrame(_ record: LinkRecord, oneOf types: Set<FrameType>) -> Bool {
        guard record.tag == .frame, !types.isEmpty, let wire = try? WireEnvelope(decoding: record.payload),
            let envelope = try? RelayEnvelope(decoding: wire.signed)
        else {
            return false
        }
        return types.contains(envelope.type)
    }
}
