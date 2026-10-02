import Foundation

extension Copy {
    /// The status line at the top of the chat list: how many phones are linked, or why none can be (MVP item 10).
    public enum Status {
        /// Running, with nobody linked yet.
        public static var looking: String {
            NSLocalizedString(
                "status.looking",
                bundle: .main,
                value: "Looking for people nearby",
                comment: "Chat list status: running, nobody linked"
            )
        }

        /// Running, with `count` phones linked.
        public static func linked(_ count: Int) -> String {
            Copy.count(
                count,
                one: NSLocalizedString(
                    "status.linked.one",
                    bundle: .main,
                    value: "Connected to %lld nearby device",
                    comment: "Chat list status: one link"
                ),
                other: NSLocalizedString(
                    "status.linked.other",
                    bundle: .main,
                    value: "Connected to %lld nearby devices",
                    comment: "Chat list status: several links; %lld is the count"
                )
            )
        }

        /// The radio has not reported yet.
        public static var starting: String {
            NSLocalizedString(
                "status.starting",
                bundle: .main,
                value: "Starting Bluetooth…",
                comment: "Chat list status: the radio has not reported yet"
            )
        }

        /// Bluetooth is switched off.
        public static var bluetoothOff: String {
            NSLocalizedString(
                "status.bluetooth-off",
                bundle: .main,
                value: "Bluetooth is off. Turn it on to reach people nearby.",
                comment: "Chat list status: Bluetooth is switched off"
            )
        }

        /// Knit may not use Bluetooth.
        public static var notAllowed: String {
            NSLocalizedString(
                "status.not-allowed",
                bundle: .main,
                value: "Knit needs Bluetooth to reach people nearby. Allow it in Settings.",
                comment: "Chat list status: the Bluetooth permission is refused"
            )
        }

        /// The device has no Bluetooth LE.
        public static var unsupported: String {
            NSLocalizedString(
                "status.unsupported",
                bundle: .main,
                value: "This device has no Bluetooth LE, so it can't reach phones nearby.",
                comment: "Chat list status: the device has no Bluetooth LE"
            )
        }

        /// The user stopped the mesh in Settings.
        public static var stopped: String {
            NSLocalizedString(
                "status.stopped",
                bundle: .main,
                value: "Mesh stopped. What you write waits here until you start it again.",
                comment: "Chat list status: the user stopped the mesh"
            )
        }

        /// The button that starts a stopped mesh.
        public static var start: String {
            NSLocalizedString(
                "status.start",
                bundle: .main,
                value: "Start",
                comment: "Chat list status: button that starts a stopped mesh"
            )
        }

        /// The one boundary of the iPhone's radio, said once (`.agents/rules/copy.md`): new people are found only while
        /// Knit is open, and in the background a message waits for a phone that can wake Knit (ADR 2026-09.khjj).
        public static var boundary: String {
            NSLocalizedString(
                "status.boundary",
                bundle: .main,
                value: """
                    Knit finds new people while it's open. In the background it stays linked to them, and some phones can wake it to \
                    deliver a message. Messages from the rest arrive when you next open Knit.
                    """,
                comment: "Where the app says once that new people are found only while it is open, and what reaches it in the background"
            )
        }
    }

    /// The list of chats.
    public enum ChatList {
        /// The screen's title.
        public static var title: String {
            NSLocalizedString("chat-list.title", bundle: .main, value: "Chats", comment: "Chat list: the screen's title")
        }

        /// The public room's name.
        public static var nearby: String {
            NSLocalizedString("chat-list.nearby", bundle: .main, value: "Nearby", comment: "The public room everyone in range shares")
        }

        /// A thread with nothing in it yet.
        public static var noMessages: String {
            NSLocalizedString(
                "chat-list.no-messages",
                bundle: .main,
                value: "No messages yet",
                comment: "Chat list: preview of an empty thread"
            )
        }

        /// A preview that names its speaker: "Sam: see you there".
        public static func preview(speaker: String, body: String) -> String {
            format(
                NSLocalizedString(
                    "chat-list.preview",
                    bundle: .main,
                    value: "%1$@: %2$@",
                    comment: "Chat list: a preview naming its speaker; %1$@ is the name, %2$@ the message"
                ),
                speaker,
                body
            )
        }

        /// The row that opens message requests.
        public static var requests: String {
            NSLocalizedString(
                "chat-list.requests",
                bundle: .main,
                value: "Message requests",
                comment: "Chat list: the row that opens message requests"
            )
        }

        /// How many requests wait, for a screen reader.
        public static func requestCount(_ count: Int) -> String {
            Copy.count(
                count,
                one: NSLocalizedString(
                    "chat-list.requests.one",
                    bundle: .main,
                    value: "%lld request waiting",
                    comment: "Chat list: one request waits"
                ),
                other: NSLocalizedString(
                    "chat-list.requests.other",
                    bundle: .main,
                    value: "%lld requests waiting",
                    comment: "Chat list: several requests wait; %lld is the count"
                )
            )
        }

        /// The first-run card's heading.
        public static var gettingStartedTitle: String {
            NSLocalizedString(
                "chat-list.getting-started.title",
                bundle: .main,
                value: "Get started",
                comment: "Chat list: the first-run card's heading"
            )
        }

        /// The first-run card.
        public static var gettingStartedBody: String {
            NSLocalizedString(
                "chat-list.getting-started.body",
                bundle: .main,
                value: "Say hello in Nearby to reach everyone in range. To message one person, tap their name there and choose Message.",
                comment: "Chat list: the first-run card"
            )
        }

        /// The first-run card's button, which opens the room.
        public static var gettingStartedAction: String {
            NSLocalizedString(
                "chat-list.getting-started.action",
                bundle: .main,
                value: "Say hello",
                comment: "Chat list: the first-run card's button"
            )
        }

        /// The button that opens Settings.
        public static var settings: String {
            NSLocalizedString(
                "chat-list.settings",
                bundle: .main,
                value: "Settings",
                comment: "Chat list: the button that opens Settings"
            )
        }

        /// A DM row whose peer is linked now, for a screen reader.
        public static var inRange: String {
            NSLocalizedString(
                "chat-list.in-range",
                bundle: .main,
                value: "In range",
                comment: "Chat list: spoken; the DM's peer is linked now"
            )
        }
    }

    /// New message: pick one person for a DM, or 2 to 7 for a group. Android's `contacts_*` strings are the starting
    /// point.
    public enum NewMessage {
        /// The chat list's button that opens the picker, and the picker's title.
        public static var title: String {
            NSLocalizedString(
                "new-message.title", bundle: .main, value: "New message", comment: "Button and screen title: start a chat or a group")
        }

        /// What the picker is for, and who is in it.
        public static var explanation: String {
            NSLocalizedString(
                "new-message.explanation",
                bundle: .main,
                value: """
                    Pick one person for a direct message, or 2 to 7 people for a group. The list shows everyone you've chatted \
                    with or verified.
                    """,
                comment: "New message: what one pick and several picks do, and who can be picked"
            )
        }

        /// Nobody to pick yet: the heading.
        public static var emptyTitle: String {
            NSLocalizedString(
                "new-message.empty.title",
                bundle: .main,
                value: "No one to message yet",
                comment: "New message: the heading when nobody can be picked yet"
            )
        }

        /// Nobody to pick yet: who appears, and how to meet them.
        public static var emptyBody: String {
            NSLocalizedString(
                "new-message.empty.body",
                bundle: .main,
                value: "People you've chatted with or verified show up here. To meet someone, say hello in Nearby.",
                comment: "New message: who appears in the list, and where to meet people"
            )
        }

        /// A pick past the cap of `count` people, us included.
        public static func full(_ count: Int) -> String {
            format(
                NSLocalizedString(
                    "new-message.full",
                    bundle: .main,
                    value: "A group can hold up to %lld people, including you.",
                    comment: "New message: the group cap was reached; %lld is the most people a group holds, the user included"
                ),
                count
            )
        }

        /// The button that opens the DM or starts the group.
        public static var start: String {
            NSLocalizedString(
                "new-message.start", bundle: .main, value: "Start chat", comment: "New message: the button that opens the chat or group")
        }
    }
}
