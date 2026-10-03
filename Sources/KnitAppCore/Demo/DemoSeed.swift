public import KnitCrypto
public import KnitMesh
import KnitStore
public import KnitWire

/// How the app was launched: `-seedDemo`, the radio state the demo reports (`-demoRadio off`), so a screen can be
/// checked in a state no real phone here is in, the unsupported device's among them (MVP item 10), the scene it
/// seeds (`-demoScene marketing`), whether it starts at onboarding (`-demoOnboarding`), what the camera answers
/// (`-demoCamera denied`), whether Choose photo picks a painted picture (`-demoPhoto`), and whether the demo posts a
/// notification to tap (`-demoNotification`).
public struct LaunchOptions: Sendable, Equatable {
    /// Whether to run the demo: seeded stores in memory, a radio that goes nowhere, and a fixed identity.
    public var seedDemo = false
    /// What the demo's radio says of itself.
    public var demoRadio = RadioState.on
    /// Who and what the demo seeds.
    public var demoScene = DemoScene.edgeCases
    /// Whether the demo starts at onboarding, as a first run does, rather than at the chat list. The UI tests walk it.
    public var demoOnboarding = false
    /// What the demo's camera answers, or `nil` for the device's own: the Simulator has no scanner, so the UI tests reach
    /// the refused and failed states only through this.
    public var demoCamera: DemoCamera.Answer?
    /// Whether Choose photo hands the cropper a painted picture rather than opening the photo library, in the demo and in
    /// a debug build's live launch: the system's picker runs outside Knit, out of a UI test's reach.
    public var demoPhoto = false
    /// Whether the demo asks to notify as it launches, then posts the room's notification each time Knit goes to the
    /// background: the demo's radio brings no messages, so a UI test would have no notification to tap.
    public var demoNotification = false

    /// The options in `arguments`, the process's own. Anything unknown is left for the system.
    public init(arguments: [String]) {
        seedDemo = arguments.contains("-seedDemo")
        if let flag = arguments.firstIndex(of: "-demoRadio"), arguments.indices.contains(flag + 1) {
            demoRadio = Self.radioStates[arguments[flag + 1]] ?? .on
        }
        if let flag = arguments.firstIndex(of: "-demoScene"), arguments.indices.contains(flag + 1) {
            demoScene = DemoScene(rawValue: arguments[flag + 1]) ?? .edgeCases
        }
        demoOnboarding = arguments.contains("-demoOnboarding")
        if let flag = arguments.firstIndex(of: "-demoCamera"), arguments.indices.contains(flag + 1) {
            demoCamera = Self.cameraAnswers[arguments[flag + 1]]
        }
        demoPhoto = arguments.contains("-demoPhoto")
        demoNotification = arguments.contains("-demoNotification")
    }

    private static let radioStates: [String: RadioState] = [
        "on": .on, "off": .off, "unauthorized": .unauthorized, "unsupported": .unsupported,
    ]

    private static let cameraAnswers: [String: DemoCamera.Answer] = ["denied": .denied, "allowed": .allowed]
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

    /// The notification the room's newest post by someone else makes, which `-demoNotification` posts, or `nil` when
    /// nobody else has posted there.
    public static func notification(in stores: MeshStores, me: NodeId) -> LocalNotification? {
        let own = stores.ownProfile.load()
        let directory = Directory(peers: stores.peers.allPeers(), me: me, myName: own.name, myPhoto: own.avatarHash)
        let context = NotificationPolicy.Context(me: me, visibleConversation: nil, directory: directory, pendingRequests: 0)
        return stores.messages.messages(in: Conversations.nearby).last { $0.senderId != me }.flatMap { post in
            NotificationPolicy.notification(for: post, isRequest: false, in: context)
        }
    }

    /// How long before `now` the demo's peers last changed their profiles.
    private static let profileAge: Int64 = 180_000

    /// Fills `stores` with `scene`, as of `now` on the wall clock, from `me`'s side. Whoever the scene gives a profile
    /// photo gets the picture `paint` makes of their ``DemoPortrait``, and a post the scene gives a photo carries the
    /// picture `snap` makes of its own: the app paints them, and a test hands in bytes of its own.
    public static func populate(
        _ stores: MeshStores,
        me: NodeId,
        now: Int64,
        scene: DemoScene,
        paint: (DemoPortrait) -> [UInt8]? = { _ in nil },
        snap: (DemoPortrait) -> [UInt8]? = { _ in nil }
    ) {
        let cast = scene.cast
        if let own = cast.me {
            let photo = own.portrait.flatMap { keep(paint($0), in: stores, at: now) }
            stores.ownProfile.save(
                OwnProfile(name: own.name, status: own.status, openToChat: true, version: now, publishedAt: now, avatarHash: photo))
        }
        var nodeIds = [DemoCast.Slot.me: me]
        for person in cast.people {
            nodeIds[person.slot] = pin(person, in: stores, at: now, paint: paint)
        }
        let groupId = cast.group.map { group in GroupId.derive((group.members + [.me]).compactMap { nodeIds[$0]?.string }) }
        var sentAt = now
        var groupStart = now
        for line in cast.lines.reversed() {
            sentAt -= line.then.rawValue
            let sender = nodeIds[line.from, default: me]
            let recipient = line.to.map { nodeIds[$0, default: me] }
            let group = line.inGroup ? groupId : nil
            if group != nil {
                groupStart = sentAt
            }
            stores.messages.save(
                MessageRecord(
                    id: line.id,
                    senderId: sender,
                    recipientId: recipient,
                    conversationId: Conversations.id(sender: sender, recipient: recipient, group: group, me: me),
                    body: line.body,
                    sentAt: sentAt,
                    arrivedAt: sender == me ? nil : sentAt,
                    delivered: line.delivered,
                    attachment: line.photo.flatMap { photo(snap($0), in: stores, at: sentAt) }
                )
            )
        }
        if let group = cast.group, let groupId {
            seed(group, id: groupId, startedAt: groupStart - DemoCast.Pause.minutes.rawValue, people: nodeIds, in: stores)
        }
        for peer in cast.accepted.compactMap({ nodeIds[$0] }) {
            stores.conversations.accept(peer.string)
        }
    }

    /// The scene's group, started at `startedAt`, with its created line and a line for each member who left.
    private static func seed(
        _ group: DemoCast.Group, id: String, startedAt: Int64, people nodeIds: [DemoCast.Slot: NodeId], in stores: MeshStores
    ) {
        let leftAt = startedAt + DemoCast.Pause.moment.rawValue
        let roster = (group.members + [.me]).compactMap { slot in
            nodeIds[slot].map { id in
                GroupMember(
                    nodeId: id.string, departed: group.departed.contains(slot), leftAt: group.departed.contains(slot) ? leftAt : nil)
            }
        }
        // `.me` is always cast, so every creator a scene names has an id.
        guard let creator = nodeIds[group.createdBy] else {
            return
        }
        stores.groups.save(
            GroupRecord(
                id: id,
                name: group.name ?? "",
                createdBy: creator.string,
                createdAt: startedAt,
                nameUpdatedAt: group.name == nil ? 0 : startedAt,
                roster: roster
            )
        )
        stores.messages.save(StatusNotices.groupCreated(id, by: creator, at: startedAt))
        for member in group.departed.compactMap({ nodeIds[$0] }) {
            stores.messages.save(StatusNotices.memberLeft(id, member: member, at: leftAt))
        }
    }

    /// Pins `person` as of `now`, wearing the photo `paint` makes of their portrait, and answers their node id.
    private static func pin(_ person: DemoCast.Person, in stores: MeshStores, at now: Int64, paint: (DemoPortrait) -> [UInt8]?) -> NodeId? {
        keys(person.slot).map { keys in
            let photo = person.portrait.flatMap { keep(paint($0), in: stores, at: now) }
            stores.peers.upsert(
                PeerRecord(
                    nodeId: keys.nodeId,
                    name: person.name,
                    status: person.status,
                    publicKey: keys.bundle.encoded,
                    capabilities: Capabilities.local.rawValue,
                    updatedAt: now - profileAge,
                    verified: person.verified,
                    openToChat: person.openToChat,
                    avatarHash: photo,
                    advertisedAvatarHash: photo
                )
            )
            return keys.nodeId
        }
    }

    /// Keeps a post's painted photo in the blob store, as the engine keeps a room post's, and answers what the post carries.
    private static func photo(_ jpeg: [UInt8]?, in stores: MeshStores, at now: Int64) -> MessageAttachment? {
        keep(jpeg, in: stores, at: now).map { MessageAttachment(hash: $0, mime: "image/jpeg") }
    }

    /// Keeps a painted photo in the blob store, as the engine keeps one it adopted, and answers its hash.
    private static func keep(_ jpeg: [UInt8]?, in stores: MeshStores, at now: Int64) -> BlobHash? {
        jpeg.map { jpeg in
            let hash = BlobHash(of: jpeg)
            stores.blobs.insert(jpeg, hash: hash, mime: "image/jpeg", storedAt: now)
            return hash
        }
    }

    /// Fixed keys for `slot`. Any 32 bytes are an Ed25519 seed and an X25519 scalar.
    private static func keys(_ slot: DemoCast.Slot) -> IdentityKeys? {
        let seed = slot.rawValue
        let count = UInt8(IdentityKeys.privateKeyByteCount)
        return IdentityKeys(signingSeed: (0..<count).map { $0 ^ seed }, agreementScalar: (0..<count).map { $0 &+ count &+ seed })
    }
}
