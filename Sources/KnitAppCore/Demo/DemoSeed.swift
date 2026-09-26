public import KnitCrypto
public import KnitMesh
import KnitStore
public import KnitWire

/// How the app was launched: `-seedDemo`, and the radio state the demo reports (`-demoRadio off`), so a screen can be
/// checked in a state no real phone here is in, the unsupported device's among them (MVP item 10).
public struct LaunchOptions: Sendable, Equatable {
    /// Whether to run the demo: seeded stores in memory, a radio that goes nowhere, and a fixed identity.
    public var seedDemo = false
    /// What the demo's radio says of itself.
    public var demoRadio = RadioState.on

    /// The options in `arguments`, the process's own. Anything unknown is left for the system.
    public init(arguments: [String]) {
        seedDemo = arguments.contains("-seedDemo")
        if let flag = arguments.firstIndex(of: "-demoRadio"), arguments.indices.contains(flag + 1) {
            demoRadio = Self.radioStates[arguments[flag + 1]] ?? .on
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

/// The demo's people and threads: a fixed identity for this device and four pinned peers, a room with a
/// conversation in it, an accepted DM, and a message request (`-seedDemo`, as on Android).
public enum DemoSeed {
    /// This device's demo identity.
    public static var identity: IdentityKeys? {
        keys(.me)
    }

    /// The demo's people, this device first. Each one's keys come from its place here, so its node id, alias and
    /// safety number are the same every launch.
    private enum Who: UInt8 {
        case me = 0
        case sam = 1
        case priya = 2
        case stranger = 3
        case otherSam = 4
    }

    private struct Person {
        let who: Who
        let name: String
        let status: String
        let verified: Bool
    }

    /// The pinned peers. Two share a name, to show a discriminated label; the stranger has none, to show an alias.
    private static let people = [
        Person(who: .sam, name: "Sam", status: "At the north gate", verified: true),
        Person(who: .priya, name: "Priya", status: "", verified: false),
        Person(who: .stranger, name: "", status: "", verified: false),
        Person(who: .otherSam, name: "Sam", status: "Lost my group", verified: false),
    ]

    private struct Line {
        let id: String
        let from: Who
        /// `nil` for a room post.
        let to: Who?
        let body: String
        var delivered = false
    }

    /// The threads, oldest first: the room, the accepted DM with the first Sam, and the request from the one with no
    /// name.
    private static let lines = [
        Line(id: "room-1", from: .sam, to: nil, body: "Is anyone else at the festival without signal?"),
        Line(id: "room-2", from: .otherSam, to: nil, body: "Same here. Knit is the only thing working."),
        Line(id: "room-3", from: .me, to: nil, body: "Meet at the food trucks at 6?", delivered: true),
        Line(id: "room-4", from: .priya, to: nil, body: "On my way."),
        Line(id: "dm-1", from: .me, to: .sam, body: "Which gate are you at?", delivered: true),
        Line(id: "dm-2", from: .sam, to: .me, body: "North gate, by the big tent."),
        Line(id: "dm-3", from: .me, to: .sam, body: "Be there in 10."),
        Line(id: "request-1", from: .stranger, to: .me, body: "Hi! Are you the one with the blue tent?"),
    ]

    /// How far apart the demo's messages were sent.
    private static let spacing: Int64 = 180_000

    /// Fills `stores`, as of `now` on the wall clock, from `me`'s side.
    public static func populate(_ stores: MeshStores, me: NodeId, now: Int64) {
        var nodeIds = [Who.me: me]
        for (person, bundle) in people.compactMap({ person in keys(person.who).map { (person, $0.bundle) } }) {
            nodeIds[person.who] = bundle.nodeId
            stores.peers.upsert(
                PeerRecord(
                    nodeId: bundle.nodeId,
                    name: person.name,
                    status: person.status,
                    publicKey: bundle.encoded,
                    capabilities: Capabilities.local.rawValue,
                    updatedAt: now - spacing,
                    verified: person.verified
                )
            )
        }
        for (index, line) in lines.enumerated() {
            let sender = nodeIds[line.from, default: me]
            let recipient = line.to.map { nodeIds[$0, default: me] }
            let sentAt = now - Int64(lines.count - index) * spacing
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
        if let sam = nodeIds[.sam] {
            stores.conversations.accept(sam.string)
        }
    }

    /// Fixed keys for `who`. Any 32 bytes are an Ed25519 seed and an X25519 scalar.
    private static func keys(_ who: Who) -> IdentityKeys? {
        let seed = who.rawValue
        let count = UInt8(IdentityKeys.privateKeyByteCount)
        return IdentityKeys(signingSeed: (0..<count).map { $0 ^ seed }, agreementScalar: (0..<count).map { $0 &+ count &+ seed })
    }
}
