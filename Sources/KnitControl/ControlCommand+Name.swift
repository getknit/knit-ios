// Apart from the enum only to keep its file inside the lint's length.

extension ControlCommand {
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
        case .avatar:
            "avatar"
        case .denyLink:
            "deny-link"
        case .allowLink:
            "allow-link"
        case .block:
            "block"
        case .unblock:
            "unblock"
        case .digest:
            "digest"
        case .custody:
            "custody"
        case .messages:
            "messages"
        case .delete(let command):
            command.name
        case .react:
            "react"
        case .typing:
            "typing"
        case .group(let command):
            command.name
        case .ratchet:
            "ratchet"
        case .stop:
            "stop"
        case .start:
            "start"
        case .quit:
            "quit"
        }
    }
}
