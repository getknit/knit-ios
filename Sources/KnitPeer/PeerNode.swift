public import KnitCrypto
public import KnitMesh
import KnitStore
public import KnitWire

/// The headless node: a ``Mesh`` on a radio, answering control commands and reporting what the mesh did, each as
/// one JSON line through `output`.
///
/// Replies carry `"reply"` with the command's name, `"ok"`, and the caller's `"tag"`; events carry `"event"`
/// (`ready`, `link`, `profile`, `message`, `sent` and `delivered`).
public actor PeerNode {
    /// This node's id.
    nonisolated public let nodeId: NodeId
    private let identity: IdentityKeys
    private let mesh: Mesh
    private let stores: MeshStores
    private let radioProfile: String
    private let clock: any MeshClock
    private let output: @Sendable (String) -> Void
    private var forwarding: Task<Void, Never>?

    /// A node for `identity` on `radio`. Nothing runs until ``start(name:)``.
    @preconcurrency
    public init(
        identity: IdentityKeys,
        stores: MeshStores,
        radio: any Radio,
        radioProfile: String,
        clock: any MeshClock,
        random: some RandomNumberGenerator & Sendable,
        linkConfiguration: LinkManager.Configuration = LinkManager.Configuration(),
        log: any KnitLog,
        output: @escaping @Sendable (String) -> Void
    ) {
        self.identity = identity
        nodeId = identity.nodeId
        self.stores = stores
        self.radioProfile = radioProfile
        self.clock = clock
        self.output = output
        mesh = Mesh(
            identity: identity,
            deviceTag: nil,
            stores: stores,
            radio: radio,
            clock: clock,
            random: random,
            linkConfiguration: linkConfiguration,
            log: log
        )
    }

    /// Starts the mesh, publishes `name` if it is new, and reports `ready`.
    public func start(name: String?) async {
        guard forwarding == nil else {
            return
        }
        let events = mesh.events
        let reporter = EventReporter(identity: identity, stores: stores, output: output)
        forwarding = Task {
            var linked: [Neighbor] = []
            for await event in events {
                linked = reporter.report(event, linked: linked)
            }
        }
        await mesh.start()
        let own = stores.ownProfile.load()
        if let name, name != own.name {
            await mesh.updateProfile(name: name, status: own.status, openToChat: own.openToChat)
        }
        output(JSONValue.object(["event": "ready", "nodeId": .string(nodeId.string), "radioProfile": .string(radioProfile)]).line)
    }

    /// Stops the mesh and the event reports.
    public func stop() async {
        await mesh.stop()
        forwarding?.cancel()
        forwarding = nil
    }

    /// Answers one control line, and whether to keep reading: `false` after `quit`.
    @discardableResult
    public func handle(_ line: String) async -> Bool {
        switch ControlRequest.parse(line) {
        case .failure(let error):
            output(JSONValue.object(["reply": "error", "ok": false, "error": .string(error.message)]).line)
            return true
        case .success(let request):
            var reply: [String: JSONValue]
            switch await answer(request.command) {
            case .success(let fields):
                reply = fields
                reply["ok"] = true
            case .failure(let error):
                reply = ["ok": false, "error": .string(error.message)]
            }
            reply["reply"] = .string(request.command.name)
            if let tag = request.tag {
                reply["tag"] = .string(tag)
            }
            output(JSONValue.object(reply).line)
            return request.command != .quit
        }
    }

    private func answer(_ command: ControlCommand) async -> Result<[String: JSONValue], ControlError> {
        switch command {
        case .status:
            return .success(await status())
        case .peers:
            let peers = stores.peers.allPeers().sorted { $0.nodeId < $1.nodeId }
            return .success(["peers": .array(peers.map { EventReporter.describe($0, identity: identity) })])
        case .links:
            return .success(await links())
        case .room(let text):
            guard let record = await mesh.postToRoom(text) else {
                return .failure(.refused("a blank message is not sent"))
            }
            return .success(["id": .string(record.id)])
        case .directMessage(let recipient, let text):
            guard let record = await mesh.sendDirectMessage(text, to: recipient) else {
                return .failure(.refused("a blank message, or one to ourselves, is not sent"))
            }
            return .success(["id": .string(record.id), "pendingKey": .bool(record.pendingKey)])
        case .accept(let conversation):
            await mesh.accept(conversation)
            return .success(["conv": .string(conversation)])
        case .name(let name, let status, let openToChat):
            let own = stores.ownProfile.load()
            let profile = (name: name ?? own.name, status: status ?? own.status, openToChat: openToChat ?? own.openToChat)
            await mesh.updateProfile(name: profile.name, status: profile.status, openToChat: profile.openToChat)
            return .success(["name": .string(profile.name), "status": .string(profile.status), "openToChat": .bool(profile.openToChat)])
        case .denyLink(let peer):
            await mesh.refuseLinks(with: peer)
            return .success(["peer": .string(peer.string)])
        case .allowLink(let peer):
            await mesh.permitLinks(with: peer)
            return .success(["peer": .string(peer.string)])
        case .digest:
            let now = clock.wallMilliseconds()
            let ids = stores.custody.liveIds(now: now).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            let fingerprint = Hex.encode(withUnsafeBytes(of: stores.custody.fingerprint(now: now).bigEndian, Array.init))
            return .success([
                "ids": .array(ids.map(JSONValue.string)), "count": .int(Int64(ids.count)), "fingerprint": .string(fingerprint),
            ])
        case .messages(let conversation, let limit):
            let messages = stores.messages.messages(in: conversation).suffix(limit)
            return .success(["conv": .string(conversation), "messages": .array(messages.map(EventReporter.describe))])
        case .quit:
            await stop()
            return .success([:])
        }
    }

    private func status() async -> [String: JSONValue] {
        let own = stores.ownProfile.load()
        let dropped = await mesh.dropped.map { (String(describing: $0.key), JSONValue.int(Int64($0.value))) }
        return [
            "nodeId": .string(nodeId.string),
            "name": .string(own.name),
            "displayName": .string(Alias.displayName(stored: own.name, nodeId: nodeId.string)),
            "alias": .string(Alias.alias(for: nodeId.string)),
            "status": .string(own.status),
            "radioProfile": .string(radioProfile),
            "links": .int(Int64(await mesh.neighbors.count)),
            "sighted": .int(Int64(await mesh.sightings.count)),
            "peers": .int(Int64(stores.peers.allPeers().count)),
            "custody": .int(Int64(stores.custody.liveIds(now: clock.wallMilliseconds()).count)),
            "dropped": .object(Dictionary(dropped) { first, _ in first }),
        ]
    }

    private func links() async -> [String: JSONValue] {
        let links = await mesh.neighbors.map { neighbor -> JSONValue in
            [
                "peer": .string(neighbor.nodeId.string),
                "version": .int(Int64(neighbor.protocolVersion)),
                "capabilities": .string(neighbor.capabilities.hex),
            ]
        }
        let sightings = await mesh.sightings.map { sighting -> JSONValue in
            [
                "peer": .string(sighting.nodeId.string),
                "rssi": .int(Int64(sighting.smoothedRssi.rounded())),
                "dwellMs": .int(sighting.dwellMilliseconds),
                "lastSeenMs": .int(sighting.lastSeenAgoMilliseconds),
                "psm": .int(Int64(sighting.advert.psm)),
                "flags": .int(Int64(sighting.advert.flags)),
            ]
        }
        return ["links": .array(links), "sightings": .array(sightings)]
    }
}

/// Turns what the mesh did into event lines.
internal struct EventReporter: Sendable {
    let identity: IdentityKeys
    let stores: MeshStores
    let output: @Sendable (String) -> Void

    /// Reports `event`, and answers the links now up, so a link event names only the peer that changed.
    func report(_ event: MeshEvent, linked: [Neighbor]) -> [Neighbor] {
        switch event {
        case .received(let record, let isRequest):
            var fields = Self.fields(of: record)
            fields["event"] = "message"
            fields["request"] = .bool(isRequest)
            output(JSONValue.object(fields).line)
        case .delivered(let id):
            output(JSONValue.object(["event": "delivered", "id": .string(id)]).line)
        case .sent(let id):
            output(JSONValue.object(["event": "sent", "id": .string(id)]).line)
        case .peerUpdated(let node):
            if let peer = stores.peers.peer(node) {
                var fields = Self.fields(of: peer, identity: identity)
                fields["event"] = "profile"
                output(JSONValue.object(fields).line)
            }
        case .neighborsChanged(let neighbors):
            let before = Set(linked.map(\.nodeId))
            let after = Set(neighbors.map(\.nodeId))
            for neighbor in neighbors where !before.contains(neighbor.nodeId) {
                output(
                    JSONValue.object([
                        "event": "link", "peer": .string(neighbor.nodeId.string), "up": true,
                        "version": .int(Int64(neighbor.protocolVersion)), "capabilities": .string(neighbor.capabilities.hex),
                    ])
                    .line
                )
            }
            for neighbor in linked where !after.contains(neighbor.nodeId) {
                output(JSONValue.object(["event": "link", "peer": .string(neighbor.nodeId.string), "up": false]).line)
            }
            return neighbors
        }
        return linked
    }

    /// A pinned peer, with the name Android would show and the safety number both sides should read.
    static func describe(_ peer: PeerRecord, identity: IdentityKeys) -> JSONValue {
        .object(fields(of: peer, identity: identity))
    }

    private static func fields(of peer: PeerRecord, identity: IdentityKeys) -> [String: JSONValue] {
        let node = peer.nodeId.string
        return [
            "peer": .string(node),
            "name": .string(peer.name),
            "displayName": .string(Alias.displayName(stored: peer.name, nodeId: node)),
            "alias": .string(Alias.alias(for: node)),
            "status": .string(peer.status),
            "openToChat": .bool(peer.openToChat),
            "verified": .bool(peer.verified),
            "capabilities": .text(peer.capabilities.map { Capabilities(rawValue: $0).hex }),
            "safetyNumber": .string(
                SafetyNumber.compute(
                    selfNodeId: identity.nodeId.string,
                    selfBundle: identity.bundle.encoded,
                    peerNodeId: node,
                    peerBundle: peer.publicKey
                )
            ),
        ]
    }

    static func describe(_ record: MessageRecord) -> JSONValue {
        .object(fields(of: record))
    }

    private static func fields(of record: MessageRecord) -> [String: JSONValue] {
        [
            "id": .string(record.id),
            "from": .string(record.senderId.string),
            "to": .text(record.recipientId?.string),
            "conv": .string(record.conversationId),
            "body": .string(record.body),
            "sentAt": .int(record.sentAt),
            "arrivedAt": record.arrivedAt.map(JSONValue.int) ?? .null,
            "delivered": .bool(record.delivered),
            "pendingKey": .bool(record.pendingKey),
        ]
    }
}
