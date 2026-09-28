import Foundation

extension Copy {
    /// The first run: welcome, then a name, then Bluetooth (MVP item 1).
    public enum Onboarding {
        /// The welcome page's heading.
        public static var welcomeTitle: String {
            NSLocalizedString(
                "onboarding.welcome.title",
                bundle: .main,
                value: "Welcome to Knit",
                comment: "Onboarding: the first page's heading"
            )
        }

        /// The line under the welcome heading.
        public static var welcomeTagline: String {
            NSLocalizedString(
                "onboarding.welcome.tagline",
                bundle: .main,
                value: "Talk to people nearby without an account, internet or cell service.",
                comment: "Onboarding: the line under the welcome heading"
            )
        }

        /// How messages travel: the heading.
        public static var hopTitle: String {
            NSLocalizedString(
                "onboarding.hop.title",
                bundle: .main,
                value: "Phone to phone",
                comment: "Onboarding: heading of how messages travel"
            )
        }

        /// How messages travel.
        public static var hopBody: String {
            NSLocalizedString(
                "onboarding.hop.body",
                bundle: .main,
                value: "Phones in range link up over Bluetooth, and messages hop from one to the next with no network in between.",
                comment: "Onboarding: how messages travel"
            )
        }

        /// What encryption covers: the heading.
        public static var sealedTitle: String {
            NSLocalizedString(
                "onboarding.sealed.title",
                bundle: .main,
                value: "Sealed end to end",
                comment: "Onboarding: heading of what is encrypted"
            )
        }

        /// What encryption covers, and what it does not.
        public static var sealedBody: String {
            NSLocalizedString(
                "onboarding.sealed.body",
                bundle: .main,
                value: """
                    Direct messages are end-to-end encrypted, so the phones that carry them can't read them. The Nearby room is open to \
                    everyone in range.
                    """,
                comment: "Onboarding: what is encrypted, and that the Nearby room is not"
            )
        }

        /// Store and forward: the heading.
        public static var carryTitle: String {
            NSLocalizedString(
                "onboarding.carry.title",
                bundle: .main,
                value: "Carried by the crowd",
                comment: "Onboarding: heading of store and forward"
            )
        }

        /// Store and forward.
        public static var carryBody: String {
            NSLocalizedString(
                "onboarding.carry.body",
                bundle: .main,
                value: """
                    Your phone holds sealed messages for others and hands them on when it meets the right phone. That's how a message \
                    crosses a crowd without a server.
                    """,
                comment: "Onboarding: how phones carry messages for each other"
            )
        }

        /// The welcome page's button.
        public static var getStarted: String {
            NSLocalizedString(
                "onboarding.get-started",
                bundle: .main,
                value: "Get started",
                comment: "Onboarding: the welcome page's button"
            )
        }

        /// Where the reader is: "Step 2 of 3".
        public static func step(_ step: Int, of total: Int) -> String {
            format(
                NSLocalizedString(
                    "onboarding.step",
                    bundle: .main,
                    value: "Step %1$lld of %2$lld",
                    comment: "Onboarding: progress; both are counts"
                ),
                step,
                total
            )
        }

        /// The name page's heading.
        public static var nameTitle: String {
            NSLocalizedString(
                "onboarding.name.title",
                bundle: .main,
                value: "What should people call you?",
                comment: "Onboarding: the name page's heading"
            )
        }

        /// What the name is for, naming the alias it falls back to.
        public static func nameBody(alias: String) -> String {
            format(
                NSLocalizedString(
                    "onboarding.name.body",
                    bundle: .main,
                    value: """
                        People nearby see this name. Leave it blank to go by your alias, %@, for now. You can change it any time in your \
                        profile.
                        """,
                    comment: "Onboarding: what the name is for; %@ is the user's alias, such as OptimallyArtfulFox"
                ),
                alias
            )
        }

        /// The name page's button once a name is typed.
        public static var nameNext: String {
            NSLocalizedString(
                "onboarding.name.next",
                bundle: .main,
                value: "Continue",
                comment: "Onboarding: the name page's button once a name is typed"
            )
        }

        /// The name page's button while the field is blank.
        public static var nameSkip: String {
            NSLocalizedString(
                "onboarding.name.skip",
                bundle: .main,
                value: "Skip for now",
                comment: "Onboarding: the name page's button while it is blank"
            )
        }

        /// The permissions page's heading.
        public static var permissionsTitle: String {
            NSLocalizedString(
                "onboarding.permissions.title",
                bundle: .main,
                value: "Let Knit find phones nearby",
                comment: "Onboarding: the permissions page's heading"
            )
        }

        /// The Bluetooth row's title.
        public static var bluetoothTitle: String {
            NSLocalizedString(
                "onboarding.bluetooth.title",
                bundle: .main,
                value: "Bluetooth",
                comment: "Onboarding: the Bluetooth permission row"
            )
        }

        /// What Bluetooth does for Knit, and the one boundary: new people are found while Knit is open, and in the
        /// background some phones' messages wait for the next time it is.
        public static var bluetoothBody: String {
            NSLocalizedString(
                "onboarding.bluetooth.body",
                bundle: .main,
                value: """
                    Finds phones in range and passes messages between them. Knit finds new people while it's open and stays linked to \
                    them in the background, though messages from some phones wait until you open Knit again.
                    """,
                comment: "Onboarding: what Bluetooth does, that new people are found only while Knit is open, and what waits"
            )
        }

        /// Bluetooth was refused, so only Settings can allow it now.
        public static var bluetoothDenied: String {
            NSLocalizedString(
                "onboarding.bluetooth.denied",
                bundle: .main,
                value: "Bluetooth is turned off for Knit. Allow it in Settings, then come back here.",
                comment: "Onboarding: the Bluetooth permission was refused"
            )
        }

        /// The notifications row's title.
        public static var notificationsTitle: String {
            NSLocalizedString(
                "onboarding.notifications.title",
                bundle: .main,
                value: "Notifications",
                comment: "Onboarding: the notifications row"
            )
        }

        /// What notifications do for Knit.
        public static var notificationsBody: String {
            NSLocalizedString(
                "onboarding.notifications.body",
                bundle: .main,
                value: "Tells you when a message arrives while Knit is in the background.",
                comment: "Onboarding: what notifications are for"
            )
        }

        /// The tag on a row the reader may skip.
        public static var optional: String {
            NSLocalizedString(
                "onboarding.optional",
                bundle: .main,
                value: "Optional",
                comment: "Onboarding: the tag on a permission the user may skip"
            )
        }

        /// A row's button that asks for a permission.
        public static var allow: String {
            NSLocalizedString(
                "onboarding.allow",
                bundle: .main,
                value: "Allow",
                comment: "Onboarding: a row's button that asks for a permission"
            )
        }

        /// What a row's button says to a screen reader: "Allow, Bluetooth".
        public static func allowLabel(_ row: String) -> String {
            format(
                NSLocalizedString(
                    "onboarding.allow.label",
                    bundle: .main,
                    value: "Allow, %@",
                    comment: "Onboarding: spoken button label; %@ is the row's title"
                ),
                row
            )
        }

        /// A row whose permission is granted.
        public static var allowed: String {
            NSLocalizedString(
                "onboarding.allowed",
                bundle: .main,
                value: "Allowed",
                comment: "Onboarding: a row whose permission is granted"
            )
        }

        /// A device with no Bluetooth LE.
        public static var unsupported: String {
            NSLocalizedString(
                "onboarding.unsupported",
                bundle: .main,
                value: """
                    This device has no Bluetooth LE, so it can't reach phones nearby. You can still open Knit and read what's already \
                    here.
                    """,
                comment: "Onboarding: the device has no Bluetooth LE"
            )
        }

        /// The last page's button.
        public static var start: String {
            NSLocalizedString("onboarding.start", bundle: .main, value: "Start meshing", comment: "Onboarding: the last page's button")
        }
    }
}
