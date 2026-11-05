#if os(iOS) && DEBUG
    import Foundation
    import KnitControl

    /// `{"cmd":"sample","action":"open"}`, or `"close"`: opens or closes the sample chats as their buttons do, so a script can
    /// watch the live mesh run under them on an iPhone nobody is at (ADR 2026-11.pydf). With no `action` it says where they
    /// stand. `open` in the reply is what happened: the launch refuses before the terms are agreed. The rest of the bridge
    /// stays the live session's, sample open or not.
    internal struct SampleCommand: Decodable {
        static let name = "sample"

        /// What to do with the sample chats.
        enum Action: String, Decodable {
            case open = "open"
            case shut = "close"
        }

        let cmd: String
        let action: Action?
        let tag: String?

        /// The command on `line`, when it is this one.
        static func parse(_ line: String) -> Self? {
            guard let command = try? JSONDecoder().decode(Self.self, from: Data(line.utf8)), command.cmd == name else {
                return nil
            }
            return command
        }

        /// Opens or closes the sample chats through `door`, and says where they stand.
        @MainActor
        func answer(_ door: SampleDoor) -> String {
            if let action {
                door.set(action == .open)
            }
            var reply: [String: JSONValue] = ["reply": .string(Self.name), "ok": true, "open": .bool(door.isOpen())]
            if let tag {
                reply["tag"] = .string(tag)
            }
            return JSONValue.object(reply).line
        }
    }

    /// The launch's way to the sample chats, which it hands the bridge once the environment is built: the bridge is made
    /// inside the environment, and the sample chats belong to the launch above it.
    @MainActor
    internal final class SampleDoor {
        var isOpen: () -> Bool = { false }
        var set: (Bool) -> Void = { _ in
            // Until the launch says, there is no door.
        }
    }
#endif
