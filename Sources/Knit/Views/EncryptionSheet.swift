#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// What a DM's or a group's encryption covers, and the limit v1 has, a point at a time in an ``InfoSheet``.
    internal enum EncryptionSheet {
        /// The points for a DM with `name`.
        static func direct(_ name: String) -> [InfoPoint] {
            [
                InfoPoint(symbol: "lock.fill", text: Copy.Chat.encryptionWho(name)),
                InfoPoint(symbol: "point.3.connected.trianglepath.dotted", text: Copy.Chat.encryptionSealed),
                InfoPoint(symbol: "face.smiling", text: Copy.Chat.encryptionReactions),
                InfoPoint(symbol: "key", text: Copy.Chat.encryptionSecrecy),
            ]
        }

        /// The points for a group.
        static var group: [InfoPoint] {
            [
                InfoPoint(symbol: "lock.fill", text: Copy.Groups.encryptionWho),
                InfoPoint(symbol: "point.3.connected.trianglepath.dotted", text: Copy.Chat.encryptionSealed),
                InfoPoint(symbol: "person.2", text: Copy.Groups.encryptionRoster),
                InfoPoint(symbol: "face.smiling", text: Copy.Chat.encryptionReactions),
                InfoPoint(symbol: "key", text: Copy.Groups.encryptionSecrecy),
            ]
        }
    }

    extension Copy.Status {
        /// The radio's boundary as an info sheet's points.
        static var boundaryPoints: [InfoPoint] {
            [
                InfoPoint(symbol: "magnifyingglass", text: boundaryOpen),
                InfoPoint(symbol: "link", text: boundaryBackground),
                InfoPoint(symbol: "clock", text: boundaryLater),
            ]
        }
    }
#endif
