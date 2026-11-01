import Foundation
import KnitCrypto
import KnitMesh
import KnitPeer
import KnitStore
import KnitSync
import KnitTestSupport
import KnitWire
import Testing

/// A wall clock a test moves by hand, starting at ``StillClock/wall``. The monotonic clock stands still and a sleeper
/// waits until it is cancelled, so no timer fires.
final class SteppingClock: MeshClock {
    private let wall = Lock(StillClock.wall)

    func wallMilliseconds() -> Int64 {
        wall.withLock { $0 }
    }

    func monotonicMilliseconds() -> Int64 {
        1000
    }

    func sleep(untilMonotonic _: Int64) async throws {
        try await Task.sleep(for: .seconds(3600))
    }

    func advance(by milliseconds: Int64) {
        wall.withLock { $0 += milliseconds }
    }
}

/// Waits, yielding, until `condition` holds, for at most five seconds.
func waitUntil(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
        if await condition() {
            return true
        }
        await Task.yield()
    }
    return false
}

/// A fresh state directory under the temporary directory.
func temporaryStateDirectory() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("knit-peer-lies-\(UInt64.random(in: 0...UInt64.max))").path
}

/// A knit-peer liar as `knit-peer run --lying` builds it, a ``Mesh`` on a ``PeerRadio`` over a state directory, with its
/// profile switches, linked by hand to an honest engine on the far end, which takes what the liar writes as a phone would.
final class LyingProfileRig {
    static let channel = ChannelID(7)

    let keys = identity(1)
    let far = identity(2)
    let directory: String
    let clock: SteppingClock
    let radio = PeerRadio()
    let forging: ForgingOwnProfileStore
    let blobs: LyingBlobStore
    let stores: MeshStores
    let mesh: Mesh
    let lies: ProfileLies
    let farEngine: MeshEngine
    let farTransport: CapturingTransport
    private let handed = Lock(0)

    /// A liar over `directory`, a fresh one unless given, with the ratchet's switch at `ratchet` on both ends.
    init(directory: String = temporaryStateDirectory(), clock: SteppingClock = SteppingClock(), ratchet: Bool = false) throws {
        self.directory = directory
        self.clock = clock
        let state = PeerState(directory: directory)
        try state.replaceIdentity(with: keys)
        let prekeys = ratchet ? try state.loadPrekeys(for: keys) : nil
        forging = ForgingOwnProfileStore(wrapping: state.profileStore())
        (stores, blobs) = LyingBlobStore.stores(over: .inMemory(ownProfileStore: forging))
        mesh = Mesh(
            identity: keys,
            prekeys: prekeys,
            deviceTag: nil,
            stores: stores,
            radio: radio,
            clock: clock,
            random: CountingGenerator(),
            configuration: MeshConfiguration(queriesBlobHolders: true, ratchet: ratchet)
        )
        lies = ProfileLies(
            mesh: mesh, stores: stores, profile: forging, blobs: blobs, identity: keys, clock: clock, stateDirectory: directory)
        let farState = PeerState(directory: directory + "-far")
        try farState.replaceIdentity(with: far)
        farTransport = CapturingTransport(peer: keys.nodeId)
        farEngine = MeshEngine(
            identity: far,
            prekeys: ratchet ? try farState.loadPrekeys(for: far) : nil,
            deviceTag: nil,
            stores: .inMemory(ownProfile: OwnProfile(name: "Far")),
            transport: farTransport,
            clock: clock,
            random: CountingGenerator(state: 0x5151_5151_5151_5151),
            configuration: MeshConfiguration(ratchet: ratchet)
        )
    }

    var markerPath: String { directory + "/" + ProfileLies.markerName }

    /// Removes both state directories.
    func remove() {
        try? FileManager.default.removeItem(atPath: directory)
        try? FileManager.default.removeItem(atPath: directory + "-far")
    }

    /// Starts the liar, names it, links the far engine as a dialer and waits until the liar has pushed its profile, which
    /// the far engine then pins. The far engine's own profile reaches the liar too.
    func start(name: String = "Liar", status: String = "lying low") async throws {
        await mesh.start()
        await mesh.updateProfile(name: name, status: status, openToChat: true)
        farEngine.start()
        try await dialProving(as: far, on: Self.channel, deliver: { radio.emit($0) }, written: { radio.records(on: Self.channel) })
        #expect(await waitUntil { self.written(.profile).isEmpty == false }, "the liar pushed its profile on the link")
        deliverToFar()
        _ = try #require(farEngine.stores.peers.peer(keys.nodeId), "the far engine pinned the liar")
        farEngine.linkUp(Neighbor(nodeId: keys.nodeId, capabilities: .local))
        deliverFromFar()
        #expect(await waitUntil { self.stores.peers.peer(self.far.nodeId) != nil }, "the liar pinned the far engine")
    }

    /// Every frame the liar wrote on the link, decoded.
    var frames: [(wire: WireEnvelope, envelope: RelayEnvelope)] {
        radio.frames(on: Self.channel).compactMap { wire in (try? RelayEnvelope(decoding: wire.signed)).map { (wire, $0) } }
    }

    /// The liar's frames of `type` on the link.
    func written(_ type: FrameType) -> [(wire: WireEnvelope, envelope: RelayEnvelope)] {
        frames.filter { $0.envelope.type == type }
    }

    /// Hands the far engine every frame the liar wrote since the last call.
    func deliverToFar() {
        let all = frames
        let from = handed.withLock { count in
            defer { count = all.count }
            return count
        }
        for (wire, envelope) in all.dropFirst(from) {
            farEngine.receive(InboundFrame(wire: wire, envelope: envelope, from: keys.nodeId))
        }
    }

    /// Hands the far engine `wire`, as the liar's radio injects it.
    func inject(_ wire: WireEnvelope) throws {
        let envelope = try RelayEnvelope(decoding: wire.signed)
        farEngine.receive(InboundFrame(wire: wire, envelope: envelope, from: keys.nodeId))
    }

    /// Hands the liar every frame the far engine sent since the last call.
    func deliverFromFar() {
        for wire in farTransport.take() {
            radio.emit(.received(Self.channel, record(.frame, wire.encoded)))
        }
    }

    /// The far engine's row for the liar.
    var farRow: PeerRecord? { farEngine.stores.peers.peer(keys.nodeId) }
}
