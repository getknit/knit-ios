public import KnitCrypto
public import KnitMesh
import KnitStore
public import KnitWire

/// How the app was launched: `-seedDemo`, the radio state the demo reports (`-demoRadio off`), so a screen can be
/// checked in a state no real phone here is in, the unsupported device's among them (MVP item 10), and the scene it
/// seeds (`-demoScene marketing`).
public struct LaunchOptions: Sendable, Equatable {
    /// Whether to run the demo: seeded stores in memory, a radio that goes nowhere, and a fixed identity.
    public var seedDemo = false
    /// What the demo's radio says of itself.
    public var demoRadio = RadioState.on
    /// Who and what the demo seeds.
    public var demoScene = DemoScene.edgeCases

    /// The options in `arguments`, the process's own. Anything unknown is left for the system.
    public init(arguments: [String]) {
        seedDemo = arguments.contains("-seedDemo")
        if let flag = arguments.firstIndex(of: "-demoRadio"), arguments.indices.contains(flag + 1) {
            demoRadio = Self.radioStates[arguments[flag + 1]] ?? .on
        }
        if let flag = arguments.firstIndex(of: "-demoScene"), arguments.indices.contains(flag + 1) {
            demoScene = DemoScene(rawValue: arguments[flag + 1]) ?? .edgeCases
        }
    }

    private static let radioStates: [String: RadioState] = [
        "on": .on, "off": .off, "unauthorized": .unauthorized, "unsupported": .unsupported,
    ]
}

/// A radio that reports one state and goes nowhere: `-seedDemo`'s transport. It never sights, dials or accepts, so
/// what the demo sends waits in custody.
public final class DemoRadio: Radio {
    /// The demo's radio advertises like an iPhone.
    public let advertisesServiceData = false
    /// And never reads anyone's GATT payload.
    public let dialsGattPeers = false
    /// Nor serves a doorbell: nobody links it to ring one.
    public let servesDoorbell = false
    /// What it reports: its state, once started.
    public let events: AsyncStream<RadioEvent>
    private let continuation: AsyncStream<RadioEvent>.Continuation
    private let state: RadioState

    /// A radio that says it is `state`.
    public init(state: RadioState) {
        self.state = state
        (events, continuation) = AsyncStream<RadioEvent>.makeStream()
    }

    deinit {
        continuation.finish()
    }

    public func start() {
        continuation.yield(.state(state))
    }

    public func stop() {
        // Nothing is open.
    }

    public func advertise(_: AdvertPayload) {
        // Nobody hears it.
    }

    public func dial(_: RadioAddress, psm _: UInt16) -> ChannelID {
        let channel = ChannelID(0)
        continuation.yield(.dialFailed(channel))
        return channel
    }

    public func write(_: [UInt8], to _: ChannelID) {
        // No channel is ever open.
    }

    public func close(_: ChannelID) {
        // No channel is ever open.
    }
}

/// The demo's identities and what it seeds: a fixed identity for this device, and the cast of the scene
/// `-demoScene` picks (`-seedDemo`, as on Android).
public enum DemoSeed {
    /// This device's demo identity, the same in every scene.
    public static var identity: IdentityKeys? {
        keys(.me)
    }

    /// The peers `scene` shows as linked, which only ``DemoMesh`` makes true: the demo's radio links nobody.
    public static func linked(in scene: DemoScene) -> [NodeId] {
        scene.cast.linked.compactMap { keys($0)?.nodeId }
    }

    /// How long before `now` the demo's peers last changed their profiles.
    private static let profileAge: Int64 = 180_000

    /// Fills `stores` with `scene`, as of `now` on the wall clock, from `me`'s side.
    public static func populate(_ stores: MeshStores, me: NodeId, now: Int64, scene: DemoScene) {
        let cast = scene.cast
        if let own = cast.me {
            stores.ownProfile.save(OwnProfile(name: own.name, status: own.status, openToChat: true, version: now, publishedAt: now))
        }
        var nodeIds = [DemoCast.Slot.me: me]
        for (person, bundle) in cast.people.compactMap({ person in keys(person.slot).map { (person, $0.bundle) } }) {
            nodeIds[person.slot] = bundle.nodeId
            stores.peers.upsert(
                PeerRecord(
                    nodeId: bundle.nodeId,
                    name: person.name,
                    status: person.status,
                    publicKey: bundle.encoded,
                    capabilities: Capabilities.local.rawValue,
                    updatedAt: now - profileAge,
                    verified: person.verified,
                    openToChat: person.openToChat
                )
            )
        }
        var sentAt = now
        for line in cast.lines.reversed() {
            sentAt -= line.then.rawValue
            let sender = nodeIds[line.from, default: me]
            let recipient = line.to.map { nodeIds[$0, default: me] }
            stores.messages.save(
                MessageRecord(
                    id: line.id,
                    senderId: sender,
                    recipientId: recipient,
                    conversationId: Conversations.id(sender: sender, recipient: recipient, me: me),
                    body: line.body,
                    sentAt: sentAt,
                    arrivedAt: sender == me ? nil : sentAt,
                    delivered: line.delivered
                )
            )
        }
        for peer in cast.accepted.compactMap({ nodeIds[$0] }) {
            stores.conversations.accept(peer.string)
        }
    }

    /// Fixed keys for `slot`. Any 32 bytes are an Ed25519 seed and an X25519 scalar.
    private static func keys(_ slot: DemoCast.Slot) -> IdentityKeys? {
        let seed = slot.rawValue
        let count = UInt8(IdentityKeys.privateKeyByteCount)
        return IdentityKeys(signingSeed: (0..<count).map { $0 ^ seed }, agreementScalar: (0..<count).map { $0 &+ count &+ seed })
    }
}
