import Foundation

extension Copy {
    /// Groups: their names, their status lines and group info (ADR 2026-09.n393). Android's `strings.xml` is the
    /// starting point (`group_*`, `chat_group_*` and `chat_notice_*`).
    public enum Groups {
        /// The title of a group with no name and nobody else in it.
        public static var unnamed: String {
            NSLocalizedString(
                "groups.unnamed", bundle: .main, value: "Group", comment: "The title of a group with no name and no other members")
        }

        /// An unnamed group's title from its members' names: "Sam", "Sam & Priya", "Dani, Sam & Priya". `nil` for nobody.
        public static func names(_ names: [String]) -> String? {
            guard let last = names.last else {
                return nil
            }
            let leading = names.dropLast()
            guard let first = leading.first else {
                return last
            }
            let list = leading.dropFirst().reduce(first) { joined, name in
                format(
                    NSLocalizedString(
                        "groups.names.list",
                        bundle: .main,
                        value: "%1$@, %2$@",
                        comment: "Joins names in an unnamed group's title; %1$@ is the names so far, %2$@ the next"
                    ),
                    joined,
                    name
                )
            }
            return format(
                NSLocalizedString(
                    "groups.names.last",
                    bundle: .main,
                    value: "%1$@ & %2$@",
                    comment: "Joins the last name in an unnamed group's title; %1$@ is the names before it, %2$@ the last"
                ),
                list,
                last
            )
        }

        /// How many people are in a group, us included.
        public static func memberCount(_ count: Int) -> String {
            Copy.count(
                count,
                one: NSLocalizedString("groups.members.one", bundle: .main, value: "%lld member", comment: "A group's size: one member"),
                other: NSLocalizedString(
                    "groups.members.other",
                    bundle: .main,
                    value: "%lld members",
                    comment: "A group's size; %lld is how many people are in it, the user included"
                )
            )
        }

        /// Group info's title, and the thread's button that opens it.
        public static var info: String {
            NSLocalizedString(
                "groups.info", bundle: .main, value: "Group info", comment: "Screen title and button: a group's members and settings")
        }

        /// Group info's member list heading.
        public static var members: String {
            NSLocalizedString("groups.info.members", bundle: .main, value: "Members", comment: "Group info: the member list's heading")
        }

        /// The action that renames a group.
        public static var rename: String {
            NSLocalizedString(
                "groups.rename", bundle: .main, value: "Rename group", comment: "Group info: the action that renames the group")
        }

        /// The rename field's label.
        public static var nameLabel: String {
            NSLocalizedString("groups.rename.label", bundle: .main, value: "Group name", comment: "Group info: the rename field's label")
        }

        /// The rename sheet's confirming button.
        public static var renameAction: String {
            NSLocalizedString(
                "groups.rename.action", bundle: .main, value: "Rename", comment: "Group info: the button that saves a new name")
        }

        /// The action that leaves a group.
        public static var leave: String {
            NSLocalizedString("groups.leave", bundle: .main, value: "Leave group", comment: "Group info: the action that leaves the group")
        }

        /// The leave confirmation's title.
        public static var leaveTitle: String {
            NSLocalizedString(
                "groups.leave.title", bundle: .main, value: "Leave group?", comment: "Group info: the leave confirmation's title")
        }

        /// What leaving does.
        public static var leaveBody: String {
            NSLocalizedString(
                "groups.leave.body",
                bundle: .main,
                value: """
                    You'll stop getting its messages, and Knit will remove the chat from this iPhone. The other members will see that \
                    you left.
                    """,
                comment: "Group info: what leaving the group does"
            )
        }

        /// The leave confirmation's button.
        public static var leaveAction: String {
            NSLocalizedString("groups.leave.action", bundle: .main, value: "Leave", comment: "Group info: the button that confirms leaving")
        }

        /// What group encryption covers, and what it does not: the name, the members and reactions (ADR 2026-10.ehe6).
        public static var encryptionBody: String {
            NSLocalizedString(
                "groups.encryption.body",
                bundle: .main,
                value: """
                    Only the group's members can read its messages or see its photos. Messages and photos are sealed before they leave \
                    your phone, so the phones that carry them can't open them. The group's name and member list travel unencrypted, so \
                    those phones can see who's in it. Reactions do too: those phones can see who reacted to a message and with which \
                    emoji, but not what it says. This version doesn't have forward secrecy yet: anyone who later gets a member's keys \
                    could open what they recorded earlier.
                    """,
                comment: "Chat: what group encryption covers"
            )
        }

        /// The composer's place once everyone else has left.
        public static var nobodyLeft: String {
            NSLocalizedString(
                "groups.nobody-left",
                bundle: .main,
                value: "Everyone else has left this group.",
                comment: "Chat: shown instead of the composer once nobody else is in the group"
            )
        }

        /// A group message waiting for a member's key.
        public static var waitingForKeys: String {
            NSLocalizedString(
                "groups.waiting-for-keys",
                bundle: .main,
                value: "Waiting for a member's key. It sends as soon as one arrives.",
                comment: "A group message's status: no member's encryption key has arrived yet"
            )
        }

        /// A stranger's group: who started it.
        public static func requestTitle(_ name: String) -> String {
            format(
                NSLocalizedString(
                    "groups.request.title",
                    bundle: .main,
                    value: "%@ added you to this group",
                    comment: "Chat: a group request; %@ is who started the group"
                ),
                name
            )
        }

        /// What accepting a group request does.
        public static var requestBody: String {
            NSLocalizedString(
                "groups.request.body",
                bundle: .main,
                value: "Accept to move this group to your chats and get notified when its members write.",
                comment: "Chat: what accepting a group request does"
            )
        }

        // MARK: Status lines

        /// "Sam created this group".
        public static func created(by name: String) -> String {
            format(
                NSLocalizedString(
                    "groups.notice.created",
                    bundle: .main,
                    value: "%@ created this group",
                    comment: "A group thread's status line; %@ is who created the group"
                ),
                name
            )
        }

        /// The user created the group.
        public static var createdByYou: String {
            NSLocalizedString(
                "groups.notice.created-you",
                bundle: .main,
                value: "You created this group",
                comment: "A group thread's status line: the user created the group"
            )
        }

        /// "Sam left the group".
        public static func left(_ name: String) -> String {
            format(
                NSLocalizedString(
                    "groups.notice.left",
                    bundle: .main,
                    value: "%@ left the group",
                    comment: "A group thread's status line; %@ is who left"
                ),
                name
            )
        }

        /// "Sam rejoined the group".
        public static func rejoined(_ name: String) -> String {
            format(
                NSLocalizedString(
                    "groups.notice.rejoined",
                    bundle: .main,
                    value: "%@ rejoined the group",
                    comment: "A group thread's status line; %@ is who came back"
                ),
                name
            )
        }

        /// "Sam renamed the group to Hikers".
        public static func renamed(by name: String, to groupName: String) -> String {
            format(
                NSLocalizedString(
                    "groups.notice.renamed",
                    bundle: .main,
                    value: "%1$@ renamed the group to %2$@",
                    comment: "A group thread's status line; %1$@ is who renamed it, %2$@ the new name"
                ),
                name,
                groupName
            )
        }
    }
}
