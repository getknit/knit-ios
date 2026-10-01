import Foundation
public import KnitWire

/// One control command, from one JSON line: on `knit-peer`'s standard input, or over USB to a debug build of the app
/// (`.agents/context/linux-peer.md` lists them with examples).
public enum ControlCommand: Equatable, Sendable {
    /// `{"cmd":"status"}`: this node, its name and its counts.
    case status
    /// `{"cmd":"peers"}`: every pinned peer, with its name, alias and safety number.
    case peers
    /// `{"cmd":"links"}`: the live links and every sighted peer.
    case links
    /// `{"cmd":"room","text":"…"}`: a Nearby post.
    case room(String)
    /// `{"cmd":"dm","to":"<node id>","text":"…"}`: a DM.
    case directMessage(to: NodeId, text: String)
    /// `{"cmd":"accept","conv":"<node id>"}`: accept a message request.
    case accept(String)
    /// `{"cmd":"name","name":"…","status":"…","openToChat":true}`: change our profile; what is left out stays, so
    /// an absent `openToChat` is not a false one.
    case name(String?, status: String?, openToChat: Bool?) // swiftlint:disable:this discouraged_optional_boolean
    /// `{"cmd":"deny-link","peer":"<node id>"}`: refuse links with a peer, both ways.
    case denyLink(NodeId)
    /// `{"cmd":"allow-link","peer":"<node id>"}`: let it link again.
    case allowLink(NodeId)
    /// `{"cmd":"digest"}`: the live custody ids and their fingerprint, to check convergence.
    case digest
    /// `{"cmd":"custody"}`: every live frame in custody, with its type, sender, recipient, group and sent time, to
    /// say why two custody sets differ.
    case custody
    /// `{"cmd":"messages","conv":"nearby","limit":20}`: a thread's newest messages and their ticks.
    case messages(String, limit: Int)
    /// One of the group commands.
    case group(GroupCommand)
    /// `{"cmd":"stop"}`: stop the mesh, closing every link, as Settings' Stop does.
    case stop
    /// `{"cmd":"start"}`: start it again.
    case start
    /// `{"cmd":"quit"}`: `knit-peer` stops and exits; the app's bridge closes the connection and runs on.
    case quit

    /// The name a reply carries back.
    public var name: String {
        switch self {
        case .status:
            "status"
        case .peers:
            "peers"
        case .links:
            "links"
        case .room:
            "room"
        case .directMessage:
            "dm"
        case .accept:
            "accept"
        case .name:
            "name"
        case .denyLink:
            "deny-link"
        case .allowLink:
            "allow-link"
        case .digest:
            "digest"
        case .custody:
            "custody"
        case .messages:
            "messages"
        case .group(let command):
            command.name
        case .stop:
            "stop"
        case .start:
            "start"
        case .quit:
            "quit"
        }
    }
}

/// A control command about groups (ADR 2026-09.n393).
public enum GroupCommand: Equatable, Sendable {
    /// `{"cmd":"group-create","members":["<node id>",…]}`: a group of those people and us, or the one they already
    /// share. Nothing is sent until its first message.
    case create([NodeId])
    /// `{"cmd":"group-send","conv":"<group id>","text":"…"}`: a message to a group.
    case send(String, text: String)
    /// `{"cmd":"group-rename","conv":"<group id>","name":"…"}`: rename a group, and tell its members.
    case rename(String, name: String)
    /// `{"cmd":"group-leave","conv":"<group id>"}`: leave a group, and tell its members.
    case leave(String)
    /// `{"cmd":"groups"}`: every group held, left ones included.
    case list

    /// The name a reply carries back.
    public var name: String {
        switch self {
        case .create:
            "group-create"
        case .send:
            "group-send"
        case .rename:
            "group-rename"
        case .leave:
            "group-leave"
        case .list:
            "groups"
        }
    }
}

/// A command and the tag the caller wants echoed on its reply.
public struct ControlRequest: Equatable, Sendable {
    /// How many messages `messages` returns when no limit is given.
    public static let defaultLimit = 20

    /// The command.
    public var command: ControlCommand
    /// Echoed as `"tag"` on the reply, so a script can match replies to requests.
    public var tag: String?

    /// A request, as a caller builds one.
    public init(command: ControlCommand, tag: String?) {
        self.command = command
        self.tag = tag
    }

    private struct Raw: Decodable {
        var cmd: String
        var text: String?
        var to: String?
        var peer: String?
        var conv: String?
        var name: String?
        var status: String?
        var openToChat: Bool? // swiftlint:disable:this discouraged_optional_boolean
        var limit: Int?
        var members: [String]?
        var tag: String?
    }

    /// Parses one line.
    public static func parse(_ line: String) -> Result<Self, ControlError> {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: Data(line.utf8)) else {
            return .failure(.notJSON)
        }
        return command(from: raw).map { Self(command: $0, tag: raw.tag) }
    }

    private static func command(from raw: Raw) -> Result<ControlCommand, ControlError> {
        switch raw.cmd {
        case "status":
            .success(.status)
        case "peers":
            .success(.peers)
        case "links":
            .success(.links)
        case "digest":
            .success(.digest)
        case "custody":
            .success(.custody)
        case "stop":
            .success(.stop)
        case "start":
            .success(.start)
        case "quit":
            .success(.quit)
        case "room":
            required(raw.text, "text").map(ControlCommand.room)
        case "dm":
            required(raw.text, "text").flatMap { text in nodeId(raw.to, "to").map { .directMessage(to: $0, text: text) } }
        case "accept":
            required(raw.conv ?? raw.peer, "conv").map(ControlCommand.accept)
        case "name":
            .success(.name(raw.name, status: raw.status, openToChat: raw.openToChat))
        case "deny-link":
            nodeId(raw.peer, "peer").map(ControlCommand.denyLink)
        case "allow-link":
            nodeId(raw.peer, "peer").map(ControlCommand.allowLink)
        case "messages":
            required(raw.conv, "conv").map { .messages($0, limit: max(1, raw.limit ?? defaultLimit)) }
        default:
            groupCommand(from: raw).map(ControlCommand.group)
        }
    }

    private static func groupCommand(from raw: Raw) -> Result<GroupCommand, ControlError> {
        switch raw.cmd {
        case "group-create":
            members(raw.members).map(GroupCommand.create)
        case "group-send":
            required(raw.conv, "conv").flatMap { conv in required(raw.text, "text").map { .send(conv, text: $0) } }
        case "group-rename":
            required(raw.conv, "conv").flatMap { conv in required(raw.name, "name").map { .rename(conv, name: $0) } }
        case "group-leave":
            required(raw.conv, "conv").map(GroupCommand.leave)
        case "groups":
            .success(.list)
        default:
            .failure(.unknownCommand(raw.cmd))
        }
    }

    private static func members(_ values: [String]?) -> Result<[NodeId], ControlError> {
        guard let values else {
            return .failure(.missing("members"))
        }
        var members: [NodeId] = []
        for value in values {
            guard let member = NodeId(value) else {
                return .failure(.invalidNodeId(value))
            }
            members.append(member)
        }
        return .success(members)
    }

    private static func required(_ value: String?, _ field: String) -> Result<String, ControlError> {
        value.map(Result.success) ?? .failure(.missing(field))
    }

    private static func nodeId(_ value: String?, _ field: String) -> Result<NodeId, ControlError> {
        required(value, field).flatMap { text in NodeId(text).map(Result.success) ?? .failure(.invalidNodeId(text)) }
    }
}

/// Why a control line was refused.
public enum ControlError: Error, Equatable, Sendable {
    /// Not a JSON object with a `cmd`.
    case notJSON
    /// A `cmd` nobody knows.
    case unknownCommand(String)
    /// A field the command needs.
    case missing(String)
    /// Not a canonical node id.
    case invalidNodeId(String)
    /// The mesh would not do it.
    case refused(String)

    /// What the reply says.
    public var message: String {
        switch self {
        case .notJSON:
            "not a JSON object with a cmd"
        case .unknownCommand(let name):
            "unknown command \(name)"
        case .missing(let field):
            "missing \(field)"
        case .invalidNodeId(let text):
            "not a node id: \(text)"
        case .refused(let reason):
            reason
        }
    }
}
