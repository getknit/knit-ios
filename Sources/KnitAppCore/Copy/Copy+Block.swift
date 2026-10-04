import Foundation

extension Copy {
    /// Blocking someone (ADR 2026-10.5wgg): on their profile, a message request, a blocked DM and Settings. The block
    /// is local to this phone, the person is never told, and the phone still passes their messages on for others.
    public enum Block {
        /// The button that blocks, on a request and in the confirmation.
        public static var block: String {
            NSLocalizedString("block.block", bundle: .main, value: "Block", comment: "Block: the button that blocks someone")
        }

        /// The button that unblocks, on a blocked DM and in the list of blocked people.
        public static var unblock: String {
            NSLocalizedString("block.unblock", bundle: .main, value: "Unblock", comment: "Block: the button that unblocks someone")
        }

        /// The profile's button that blocks the person.
        public static func blockPerson(_ name: String) -> String {
            format(
                NSLocalizedString(
                    "block.block-person",
                    bundle: .main,
                    value: "Block %@",
                    comment: "Profile: blocks the person; %@ is their name"
                ),
                name
            )
        }

        /// The profile's button that unblocks the person.
        public static func unblockPerson(_ name: String) -> String {
            format(
                NSLocalizedString(
                    "block.unblock-person",
                    bundle: .main,
                    value: "Unblock %@",
                    comment: "Profile: unblocks the person; %@ is their name"
                ),
                name
            )
        }

        /// The badge on a blocked person's profile.
        public static var badge: String {
            NSLocalizedString("block.badge", bundle: .main, value: "Blocked", comment: "Profile: says the person is blocked")
        }

        /// The confirmation's title.
        public static func confirmTitle(_ name: String) -> String {
            format(
                NSLocalizedString(
                    "block.confirm.title",
                    bundle: .main,
                    value: "Block %@?",
                    comment: "Block: the confirmation's title; %@ is the person's name"
                ),
                name
            )
        }

        /// What blocking does, in the confirmation.
        public static var confirmBody: String {
            NSLocalizedString(
                "block.confirm.body",
                bundle: .main,
                value: """
                    You won't see their messages or get their notifications, and Knit doesn't tell them. Your phone still passes \
                    their messages on to others.
                    """,
                comment: "Block: what blocking does, in the confirmation"
            )
        }

        /// What a blocked person's DM shows in place of the composer.
        public static func barTitle(_ name: String) -> String {
            format(
                NSLocalizedString(
                    "block.bar.title",
                    bundle: .main,
                    value: "You blocked %@",
                    comment: "Chat: in place of the composer in a blocked person's DM; %@ is their name"
                ),
                name
            )
        }

        /// What the bar adds, over Unblock.
        public static var barBody: String {
            NSLocalizedString(
                "block.bar.body",
                bundle: .main,
                value: "Their messages are hidden. Unblock them to send a message.",
                comment: "Chat: under the blocked bar's title, over Unblock"
            )
        }

        /// Settings' row, and the title of the screen it opens.
        public static var listTitle: String {
            NSLocalizedString(
                "block.list.title",
                bundle: .main,
                value: "Blocked people",
                comment: "Settings: the row and the screen listing everyone blocked"
            )
        }

        /// Nobody is blocked.
        public static var empty: String {
            NSLocalizedString(
                "block.list.empty",
                bundle: .main,
                value: "You haven't blocked anyone",
                comment: "Blocked people: nobody is blocked"
            )
        }

        /// What unblocking does, under the list.
        public static var listFooter: String {
            NSLocalizedString(
                "block.list.footer",
                bundle: .main,
                value: """
                    Unblocking someone brings back the messages they sent before you blocked them. Knit never tells anyone you've \
                    blocked them.
                    """,
                comment: "Blocked people: what unblocking does"
            )
        }
    }
}
