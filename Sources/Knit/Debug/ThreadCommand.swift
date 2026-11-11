#if os(iOS) && DEBUG
    import Foundation
    import KnitControl

    /// `{"cmd":"open-thread","conv":"<id>"}`: opens a thread as a tapped notification does, so a device check can look at
    /// what a thread draws on an iPhone nobody is at (a link's card, ADR 2026-11.hcvg). `conv` is `nearby`, a peer's node id
    /// or a group's `g-…` id. The sample chats close first, as for a notification.
    internal struct ThreadCommand: Decodable {
        static let name = "open-thread"

        let cmd: String
        let conv: String
        let tag: String?

        /// The command on `line`, when it is this one.
        static func parse(_ line: String) -> Self? {
            guard let command = try? JSONDecoder().decode(Self.self, from: Data(line.utf8)), command.cmd == name else {
                return nil
            }
            return command
        }

        /// Opens ``conv`` through `door`.
        @MainActor
        func answer(_ door: ThreadDoor) -> String {
            door.open(conv)
            var reply: [String: JSONValue] = ["reply": .string(Self.name), "ok": true, "conv": .string(conv)]
            if let tag {
                reply["tag"] = .string(tag)
            }
            return JSONValue.object(reply).line
        }
    }

    /// The launch's way to a thread, which it hands the bridge with ``SampleDoor``: the screens belong to the launch above
    /// the environment the bridge is made in.
    @MainActor
    internal final class ThreadDoor {
        var open: (String) -> Void = { _ in
            // Until the launch says, there is no door.
        }
    }
#endif
