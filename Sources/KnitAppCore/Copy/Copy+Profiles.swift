import Foundation

extension Copy {
    /// A profile: another person's, or the user's own.
    public enum Profile {
        /// The own profile's title.
        public static var title: String {
            NSLocalizedString("profile.title", bundle: .main, value: "Profile", comment: "Own profile: the screen's title")
        }

        /// The section of what peers see.
        public static var publicSection: String {
            NSLocalizedString(
                "profile.section.public",
                bundle: .main,
                value: "What people see",
                comment: "Own profile: the section peers can read"
            )
        }

        /// The section of what belongs to this device.
        public static var deviceSection: String {
            NSLocalizedString(
                "profile.section.device",
                bundle: .main,
                value: "This device",
                comment: "Own profile: the section about this device"
            )
        }

        /// The display name field.
        public static var nameLabel: String {
            NSLocalizedString("profile.name", bundle: .main, value: "Display name", comment: "Own profile: the display name field")
        }

        /// The status field.
        public static var statusLabel: String {
            NSLocalizedString("profile.status", bundle: .main, value: "Status", comment: "Profile: the status line")
        }

        /// The node id row.
        public static var nodeIdLabel: String {
            NSLocalizedString("profile.node-id", bundle: .main, value: "Node ID", comment: "Profile: the node id row")
        }

        /// The alias row.
        public static var aliasLabel: String {
            NSLocalizedString("profile.alias", bundle: .main, value: "Alias", comment: "Profile: the alias row")
        }

        /// What the alias is.
        public static var aliasFooter: String {
            NSLocalizedString(
                "profile.alias.footer",
                bundle: .main,
                value: "Your alias comes from your node ID, so every phone shows the same one. People see it until you set a name.",
                comment: "Own profile: what the alias is"
            )
        }

        /// The open-to-chat switch.
        public static var openToChat: String {
            NSLocalizedString("profile.open-to-chat", bundle: .main, value: "Open to chat", comment: "Profile: the open-to-chat flag")
        }

        /// What the open-to-chat switch says to peers.
        public static var openToChatFooter: String {
            NSLocalizedString(
                "profile.open-to-chat.footer",
                bundle: .main,
                value: "Lets people nearby know you're up for a conversation.",
                comment: "Own profile: what the open-to-chat flag tells peers"
            )
        }

        /// The number of UTF-16 units a field has left.
        public static func remaining(_ count: Int) -> String {
            format(
                NSLocalizedString(
                    "profile.remaining",
                    bundle: .main,
                    value: "%lld left",
                    comment: "Own profile: characters left; a count"
                ),
                count
            )
        }

        /// The button that opens a DM.
        public static var message: String {
            NSLocalizedString("profile.message", bundle: .main, value: "Message", comment: "Profile: the button that opens a DM")
        }

        /// The peer is linked now.
        public static var inRange: String {
            NSLocalizedString("profile.in-range", bundle: .main, value: "In range", comment: "Profile: the person's phone is linked now")
        }

        /// The peer is not linked now.
        public static var outOfRange: String {
            NSLocalizedString(
                "profile.out-of-range",
                bundle: .main,
                value: "Not in range",
                comment: "Profile: the person's phone is not linked now"
            )
        }

        /// The encryption section.
        public static var encryptionSection: String {
            NSLocalizedString("profile.encryption", bundle: .main, value: "Encryption", comment: "Profile: the encryption section")
        }

        /// A peer the user has verified.
        public static var verified: String {
            NSLocalizedString("profile.verified", bundle: .main, value: "Verified", comment: "Profile: the user compared safety numbers")
        }

        /// A peer the user has not verified.
        public static var notVerified: String {
            NSLocalizedString(
                "profile.not-verified",
                bundle: .main,
                value: "Not verified",
                comment: "Profile: the user has not compared safety numbers"
            )
        }

        /// No key yet, so no safety number.
        public static var noKey: String {
            NSLocalizedString(
                "profile.no-key",
                bundle: .main,
                value: "Your phones haven't exchanged encryption keys yet. That happens on its own once their profile reaches you.",
                comment: "Profile: no key pinned yet"
            )
        }

        /// The safety number row.
        public static var safetyNumber: String {
            NSLocalizedString("profile.safety-number", bundle: .main, value: "Safety number", comment: "Profile: the safety number")
        }

        /// How to use the safety number.
        public static func safetyNumberCaption(_ name: String) -> String {
            format(
                NSLocalizedString(
                    "profile.safety-number.caption",
                    bundle: .main,
                    value: """
                        Compare this number with %@ in person. If both phones show the same number, no one is intercepting your direct \
                        messages.
                        """,
                    comment: "Profile: how to use the safety number; %@ is the person's name"
                ),
                name
            )
        }

        /// The button that marks a peer verified.
        public static var markVerified: String {
            NSLocalizedString(
                "profile.mark-verified",
                bundle: .main,
                value: "Mark as verified",
                comment: "Profile: marks the person verified"
            )
        }

        /// The button that clears a verification.
        public static var clearVerification: String {
            NSLocalizedString(
                "profile.clear-verification",
                bundle: .main,
                value: "Clear verification",
                comment: "Profile: clears the verification"
            )
        }
    }
}
