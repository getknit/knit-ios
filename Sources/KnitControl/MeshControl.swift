import Foundation
public import KnitCrypto
public import KnitMesh
public import KnitStore
public import KnitWire

/// What the control surface changes a node through: the ``Mesh`` itself in `knit-peer`, or the app's session in front
/// of its mesh, so that a command shows on the phone's screens as a tap would.
public protocol ControlActions: Sendable {
    /// Starts the mesh and its radio.
    func start() async
    /// Stops the radio and closes every link.
    func stop() async
    /// Posts to the Nearby room, quoting the message it replies to if it replies.
    func postToRoom(_ text: String, photo: OutgoingPhoto?, replyTo: MessageReply?, mentions: [MessageMention]) async -> MessageRecord?
    /// Sends a DM, quoting the message it replies to if it replies.
    func sendDirectMessage(
        _ text: String, to recipient: NodeId, photo: OutgoingPhoto?, replyTo: MessageReply?, mentions: [MessageMention]
    ) async -> MessageRecord?
    /// A photo's bytes as the picture this node already holds them as, or `nil` (ADR 2026-10.f3mv).
    func heldPhoto(picked: [UInt8]) async -> OutgoingPhoto?
    /// Accepts a message request.
    func accept(_ conversationId: String) async
    /// Changes our profile and floods it.
    func updateProfile(name: String, status: String, openToChat: Bool) async
    /// Sets our photo, a JPEG, or clears it with `nil`, and floods the profile that names it.
    func setAvatar(_ jpeg: [UInt8]?) async
    /// Makes a group with `others`, or opens the one they already share.
    func createGroup(with others: [NodeId]) async -> GroupRecord?
    /// Sends a message to a group, quoting the message it replies to if it replies.
    func sendGroupMessage(
        _ text: String, to groupId: String, photo: OutgoingPhoto?, replyTo: MessageReply?, mentions: [MessageMention]
    ) async -> MessageRecord?
    /// Renames a group and floods the change.
    func renameGroup(_ groupId: String, to name: String) async -> GroupRecord?
    /// Leaves a group, telling its members.
    func leaveGroup(_ groupId: String) async -> Bool
    /// Deletes one message here, sending nothing (ADR 2026-10.u7cq).
    func deleteMessage(_ id: String) async -> Bool
    /// Deletes a whole thread here, sending nothing.
    func deleteChat(_ conversationId: String) async -> Bool
    /// The quote a reply to message `messageId` carries, as this node's own composer writes one, or `nil` to leave it to
    /// the control surface (ADR 2026-10.mn29).
    func quote(of messageId: String) async -> MessageReply?
    /// The mention of `person` this node's own composer writes, or `nil` to leave it to the control surface (ADR
    /// 2026-10.nbhj).
    func mention(of person: NodeId) async -> MessageMention?
    /// Reacts to a message, or takes our reaction back, and answers what we hold now (ADR 2026-10.ehe6).
    func react(to messageId: String, with emoji: String) async -> ReactionRecord?
    /// Tells a thread we are typing, at most once a throttle's interval, and answers whether a cue went out.
    func noteTyping(in thread: String) async -> Bool
    /// Blocks a peer (ADR 2026-10.5wgg).
    func block(_ peer: NodeId) async
    /// Unblocks a peer.
    func unblock(_ peer: NodeId) async
}

extension Mesh: ControlActions {}

/// Answers control lines for one node, and turns what its mesh did into event lines: the protocol `knit-peer` speaks
/// on standard input and output, and a debug build of the app speaks over its bridge.
///
/// Replies carry `"reply"` with the command's name, `"ok"`, and the caller's `"tag"`; events carry `"event"`
/// (`ready`, `link`, `profile`, `message`, `sent`, `delivered`, `reaction`, `typing`, `radio` and `group`).
public actor MeshControl {
    /// One reply line, and whether the caller asked to quit.
    public struct Reply: Equatable, Sendable {
        /// The line to write back.
        public let line: String
        /// Whether the command was `quit`.
        public let quits: Bool
    }

    /// This node's id.
    nonisolated public let nodeId: NodeId
    private let bundle: PublicKeyBundle
    let mesh: Mesh
    let actions: any ControlActions
    let stores: MeshStores
    private let clock: any MeshClock
    private let details: [String: JSONValue]
    private let sample: (@Sendable () -> [String: JSONValue])?
    private let keepAvatar: (@Sendable ([UInt8]?) -> Void)?
    private var linked: [Neighbor] = []

    /// A control surface for `mesh`, whose keys are `bundle`. It changes the node through `actions`, the mesh itself
    /// when there are none. `details` join the `ready` event and the `status` reply, to say what kind of node answers.
    /// `sample`, read at each `status`, joins it too, for what only the host can measure, such as its memory.
    /// `keepAvatar` hears each photo an `avatar` command sets, so a host whose blobs live in memory can keep its own
    /// across a restart.
    @preconcurrency
    public init(
        bundle: PublicKeyBundle,
        mesh: Mesh,
        actions: (any ControlActions)? = nil,
        stores: MeshStores,
        clock: any MeshClock,
        details: [String: JSONValue] = [:],
        sample: (@Sendable () -> [String: JSONValue])? = nil,
        keepAvatar: (@Sendable ([UInt8]?) -> Void)? = nil
    ) {
        self.bundle = bundle
        nodeId = bundle.nodeId
        self.mesh = mesh
        self.actions = actions ?? mesh
        self.stores = stores
        self.clock = clock
        self.details = details
        self.sample = sample
        self.keepAvatar = keepAvatar
    }

    /// The `ready` event: who answers, with the `details`.
    nonisolated public var ready: String {
        var fields = details
        fields["event"] = "ready"
        fields["nodeId"] = .string(nodeId.string)
        return JSONValue.object(fields).line
    }

    /// Answers one control line.
    public func handle(_ line: String) async -> Reply {
        switch ControlRequest.parse(line) {
        case .failure(let error):
            return Reply(line: JSONValue.object(["reply": "error", "ok": false, "error": .string(error.message)]).line, quits: false)
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
            return Reply(line: JSONValue.object(reply).line, quits: request.command == .quit)
        }
    }

    /// The event lines for what the mesh did. A link event names only a peer whose link changed.
    public func report(_ event: MeshEvent) -> [String] {
        switch event {
        case .received(let record, let isRequest):
            var fields = ControlLines.fields(of: record)
            fields["event"] = "message"
            fields["request"] = .bool(isRequest)
            return [JSONValue.object(fields).line]
        case .delivered(let id):
            return [JSONValue.object(["event": "delivered", "id": .string(id)]).line]
        case .sent(let id):
            return [JSONValue.object(["event": "sent", "id": .string(id)]).line]
        case .reacted(let reaction):
            return [JSONValue.object(ControlLines.fields(of: reaction).merging(["event": "reaction"]) { $1 }).line]
        case .peerUpdated(let node):
            guard let peer = stores.peers.peer(node) else {
                return []
            }
            // A profile event says when the block followed someone's new keys (`MeshEngine.continueBlock`).
            var fields = ControlLines.fields(of: peer, bundle: bundle, blocked: stores.blocks.blockedNodeIds().contains(node))
            fields["event"] = "profile"
            return [JSONValue.object(fields).line]
        case .neighborsChanged(let neighbors):
            defer { linked = neighbors }
            return ControlLines.linkChanges(from: linked, to: neighbors)
        case .radioChanged(let state):
            return [JSONValue.object(["event": "radio", "state": .string("\(state)")]).line]
        case .groupChanged(let id):
            guard let group = stores.groups.group(id) else {
                return []
            }
            var fields = ControlLines.fields(of: group)
            fields["event"] = "group"
            return [JSONValue.object(fields).line]
        case .attachmentArrived(let hash):
            return [JSONValue.object(["event": "attachment", "hash": .string(hash.string)]).line]
        case .typing(let picture):
            return [JSONValue.object(["event": "typing", "typing": ControlLines.typing(picture)]).line]
        }
    }

    private func answer(_ command: ControlCommand) async -> Result<[String: JSONValue], ControlError> {
        switch command {
        case .status:
            return .success(await status())
        case .peers:
            return .success(peers())
        case .links:
            return .success(await links())
        case .room(let text, let photo, let replyTo, let mentions):
            return await send(text, photo: photo, replyTo: replyTo, mentions: mentions, to: .room)
        case .directMessage(let recipient, let text, let photo, let replyTo, let mentions):
            return await send(text, photo: photo, replyTo: replyTo, mentions: mentions, to: .direct(recipient))
        case .accept(let conversation):
            await actions.accept(conversation)
            return .success(["conv": .string(conversation)])
        case .name(let name, let status, let openToChat):
            return .success(await rename(name, status: status, openToChat: openToChat))
        case .avatar(let source):
            return await setAvatar(from: source)
        case .denyLink(let peer), .allowLink(let peer):
            return .success(await setLinks(with: peer, allowed: command == .allowLink(peer)))
        case .block(let peer), .unblock(let peer):
            return .success(await setBlocked(peer, blocked: command == .block(peer)))
        case .digest:
            return .success(digest())
        case .custody:
            let frames = stores.custody.liveFrames(now: clock.wallMilliseconds())
                .sorted { $0.envelope.id.utf8.lexicographicallyPrecedes($1.envelope.id.utf8) }
            return .success(["frames": .array(frames.map { ControlLines.describe($0.envelope) })])
        case .messages(let conversation, let limit):
            return .success(["conv": .string(conversation), "messages": .array(messages(in: conversation, limit: limit))])
        case .delete(let command):
            return await answer(command)
        case .react(let id, let emoji):
            return await react(to: id, with: emoji)
        case .typing(let conversation):
            return .success(["conv": .string(conversation), "sent": .bool(await actions.noteTyping(in: conversation))])
        case .group(let command):
            return await answer(command)
        case .ratchet(let reset):
            return .success(await ratchet(resetting: reset))
        case .stop, .start:
            await (command == .stop ? actions.stop() : actions.start())
            return .success(["running": .bool(await mesh.isRunning)])
        case .quit:
            return .success([:])
        }
    }

    /// The newest `limit` messages of `conversation` as lines, each with its ticks and the reactions standing on it as
    /// `{reactor: emoji}`, Android's bridge's shape, and, for one carrying a photo, whether the photo's bytes are here, so
    /// a run can tell a photo that arrived from one still owed. A message the
    /// content filter flagged, or has yet to screen, says so in `moderation` (ADR 2026-10.e4kz).
    private func messages(in conversation: String, limit: Int) -> [JSONValue] {
        let messages = stores.messages.messages(in: conversation).suffix(limit)
        let held = stores.blobs.held(among: Set(messages.compactMap(\.attachment?.hash)))
        let reactions = ControlLines.reactions(stores.messages.reactions(in: conversation))
        return messages.map { message in
            var fields = ControlLines.fields(of: message)
            fields["reactions"] = reactions[ExactKey(message.id)] ?? .object([:])
            if let hash = message.attachment?.hash {
                fields["attachmentHeld"] = .bool(held.contains(hash))
            }
            if message.moderation == .flagged {
                fields["moderation"] = "flagged"
            } else if message.moderation == .waiting {
                fields["moderation"] = "waiting"
            }
            return JSONValue.object(fields)
        }
    }

    private func answer(_ command: GroupCommand) async -> Result<[String: JSONValue], ControlError> {
        switch command {
        case .create(let members):
            guard let group = await actions.createGroup(with: members) else {
                return .failure(.refused("a group takes one to seven others"))
            }
            return .success(ControlLines.fields(of: group))
        case .send(let conversation, let text, let photo, let replyTo, let mentions):
            return await send(text, photo: photo, replyTo: replyTo, mentions: mentions, to: .group(conversation))
        case .rename(let conversation, let name):
            guard let group = await actions.renameGroup(conversation, to: name) else {
                return .failure(.refused("a blank name, or a group we are not in, is not renamed"))
            }
            return .success(ControlLines.fields(of: group))
        case .leave(let conversation):
            guard await actions.leaveGroup(conversation) else {
                return .failure(.refused("not in that group"))
            }
            return .success(["conv": .string(conversation)])
        case .list:
            return .success(["groups": .array(stores.groups.groups().map { .object(ControlLines.fields(of: $0)) })])
        }
    }

    private func status() async -> [String: JSONValue] {
        let own = stores.ownProfile.load()
        let dropped = await mesh.dropped.map { (String(describing: $0.key), JSONValue.int(Int64($0.value))) }
        var fields = details
        fields.merge(sample?() ?? [:]) { _, sampled in sampled }
        fields.merge([
            "nodeId": .string(nodeId.string),
            "name": .string(own.name),
            "displayName": .string(Alias.displayName(stored: own.name, nodeId: nodeId.string)),
            "alias": .string(Alias.alias(for: nodeId.string)),
            "status": .string(own.status),
            "avatarHash": .text(own.avatarHash?.string),
            "running": .bool(await mesh.isRunning),
            "links": .int(Int64(await mesh.neighbors.count)),
            "sighted": .int(Int64(await mesh.sightings.count)),
            "peers": .int(Int64(stores.peers.allPeers().count)),
            "groups": .int(Int64(stores.groups.groups().count)),
            "custody": .int(Int64(stores.custody.liveIds(now: clock.wallMilliseconds()).count)),
            "dropped": .object(Dictionary(dropped) { first, _ in first }),
            "files": ControlLines.describe(await mesh.files),
            "blobs": ControlLines.describe(await mesh.blobs),
            "rings": .int(Int64(await mesh.rings)),
            "rung": .int(Int64(await mesh.ringsHeard)),
            "seeking": .bool(await mesh.isSeeking),
            "seekWakes": .int(Int64(await mesh.seekWakes)),
            "seekSpells": .int(Int64(await mesh.seekSpells)),
            "footprint": ControlLines.describe(await mesh.footprint),
            "router": ControlLines.describe(await mesh.routerCounters),
            "typing": ControlLines.typing(await mesh.typing),
        ]) { _, own in own }
        return fields
    }
}

/// The answers that read or change one thing each, kept apart from the actor's body.
extension MeshControl {
    /// Refuses or permits links with `peer`, as `deny-link` and `allow-link` ask.
    /// Every pinned peer, in node id order, each saying whether we blocked them.
    private func peers() -> [String: JSONValue] {
        let peers = stores.peers.allPeers().sorted { $0.nodeId < $1.nodeId }
        let blocked = stores.blocks.blockedNodeIds()
        return ["peers": .array(peers.map { .object(ControlLines.fields(of: $0, bundle: bundle, blocked: blocked.contains($0.nodeId))) })]
    }

    /// Blocks `peer` or unblocks them, through the actions, as their profile's button would (ADR 2026-10.5wgg).
    private func setBlocked(_ peer: NodeId, blocked: Bool) async -> [String: JSONValue] {
        if blocked {
            await actions.block(peer)
        } else {
            await actions.unblock(peer)
        }
        return ["peer": .string(peer.string)]
    }

    private func setLinks(with peer: NodeId, allowed: Bool) async -> [String: JSONValue] {
        if allowed {
            await mesh.permitLinks(with: peer)
        } else {
            await mesh.refuseLinks(with: peer)
        }
        return ["peer": .string(peer.string)]
    }

    /// Changes what is given of our profile and keeps the rest: an absent `openToChat` is not a false one.
    private func rename(
        _ name: String?,
        status: String?,
        openToChat: Bool? // swiftlint:disable:this discouraged_optional_boolean
    ) async -> [String: JSONValue] {
        let own = stores.ownProfile.load()
        let profile = (name: name ?? own.name, status: status ?? own.status, openToChat: openToChat ?? own.openToChat)
        await actions.updateProfile(name: profile.name, status: profile.status, openToChat: profile.openToChat)
        return ["name": .string(profile.name), "status": .string(profile.status), "openToChat": .bool(profile.openToChat)]
    }

    /// Sets our photo from where the command says, and answers its hash, or `null` once cleared.
    private func setAvatar(from source: AvatarSource) async -> Result<[String: JSONValue], ControlError> {
        let jpeg: [UInt8]?
        switch source {
        case .bytes(let bytes):
            jpeg = bytes
        case .file(let path):
            guard let data = FileManager.default.contents(atPath: path) else {
                return .failure(.refused("cannot read \(path)"))
            }
            jpeg = [UInt8](data)
        case .clear:
            jpeg = nil
        }
        await actions.setAvatar(jpeg)
        keepAvatar?(jpeg)
        return .success(["avatarHash": .text(stores.ownProfile.load().avatarHash?.string)])
    }

    /// The live custody ids and their fingerprint, to compare with another node's.
    private func digest() -> [String: JSONValue] {
        let now = clock.wallMilliseconds()
        let ids = stores.custody.liveIds(now: now).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let fingerprint = Hex.encode(withUnsafeBytes(of: stores.custody.fingerprint(now: now).bigEndian, Array.init))
        return ["ids": .array(ids.map(JSONValue.string)), "count": .int(Int64(ids.count)), "fingerprint": .string(fingerprint)]
    }
}
