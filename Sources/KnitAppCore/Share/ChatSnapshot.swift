import Foundation

/// The chats the share sheet offers, as the app last listed them (ADR 2026-10.z7a8): the chat list's rows in its
/// order, with the room first, accepted DMs and groups still held, and no request or blocked person, as Android's "Share
/// to…" reads its chat list (`ShareTargetScreen.kt`). The app writes it to the App Group whenever the list changes, and
/// the sheet, which opens no database, reads it.
public struct ChatSnapshot: Sendable, Equatable, Codable {
    /// One chat the sheet offers.
    public struct Row: Sendable, Equatable, Codable, Identifiable {
        /// What the chat is. Its raw value is what the snapshot stores, so a case keeps its number.
        public enum Kind: Int, Sendable, Codable {
            case room = 1
            case direct = 2
            case group = 3
        }

        /// The thread: `nearby`, a peer's node id or a group's id.
        public var id: String
        /// The room's name, the peer's label, or the group's title.
        public var title: String
        /// What the chat is.
        public var kind: Kind
        /// The key its face's tint comes from (``Face/key``), empty for the room.
        public var faceKey: String
        /// The letter a person's face shows (``Face/initial``), empty for a group and the room.
        public var initial: String

        /// The face the sheet draws: the tint and letter, or a glyph. Photos stay in the app's blob store.
        public var face: Face {
            switch kind {
            case .room:
                .room
            case .direct:
                Face(kind: .person, key: faceKey, initial: initial, photo: nil, members: [])
            case .group:
                .group(faceKey, photo: nil, members: [])
            }
        }
    }

    /// The layout this build writes and reads.
    public static let currentVersion = 1
    /// The file's name in ``ShareInbox/root``.
    public static let fileName = "chats.json"

    /// The layout the snapshot was written in.
    public var version = Self.currentVersion
    /// The chats, in the chat list's order.
    public var rows: [Row]

    /// The chats `list` shows.
    public init(_ list: ChatListState) {
        rows = list.rows.map { row in
            Row(
                id: row.id,
                title: row.title,
                kind: row.isRoom ? .room : row.isGroup ? .group : .direct,
                faceKey: row.face.key,
                initial: row.face.initial
            )
        }
    }

    /// The snapshot in `inbox`, or `nil` when the app has written none, it cannot be read yet (before the first unlock),
    /// or it is of another version.
    public static func read(from inbox: ShareInbox) -> Self? {
        guard let data = try? Data(contentsOf: inbox.root.appendingPathComponent(fileName)),
            let snapshot = try? JSONDecoder().decode(Self.self, from: data),
            snapshot.version == currentVersion
        else {
            return nil
        }
        return snapshot
    }

    /// Writes the snapshot to `inbox`, in place of the last, unless it is the same.
    public func write(to inbox: ShareInbox) {
        guard Self.read(from: inbox) != self else {
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(self) else {
            return
        }
        try? FileManager.default.createDirectory(at: inbox.root, withIntermediateDirectories: true)
        try? data.write(to: inbox.root.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Removes the snapshot from `inbox`, as a reset does, so the sheet offers nothing until the app lists chats again.
    public static func remove(from inbox: ShareInbox) {
        try? FileManager.default.removeItem(at: inbox.root.appendingPathComponent(fileName))
    }
}
