import Foundation

extension Copy {
    /// Internet relays' settings, consent sheets and refusals, a debug build's alone until the maintainer approves the plane
    /// (ADR 2026-11.adrq, knit-next's "Internet relays" and "Relay invite" strings). No string names any part of a link.
    public enum Relays {
        /// The section's header (`relays_title`).
        public static var title: String {
            NSLocalizedString(
                "relays.title",
                bundle: .main,
                value: "Internet relays",
                comment: "Settings: the Internet relays section's header"
            )
        }

        /// The master switch (`settings_internet_relays_title`).
        public static var switchTitle: String {
            NSLocalizedString(
                "relays.switch",
                bundle: .main,
                value: "Use Internet relays",
                comment: "Settings: the switch that turns Internet relays on"
            )
        }

        /// What relays do, and the one boundary: text messages with contacts, only while Knit is open.
        public static var footer: String {
            NSLocalizedString(
                "relays.footer",
                bundle: .main,
                value: """
                    Send direct messages over the Internet when the person you're writing to is out of Bluetooth range. Relays \
                    carry text messages with your contacts, and they run only while Knit is open, so a message that comes \
                    through one while Knit is closed arrives the next time you open it.
                    """,
                comment: "Settings: below the Internet relays switch; names what relays carry and that they run only while Knit is open"
            )
        }

        /// The mark on the house relay, and on it alone.
        public static var knitsRelay: String {
            NSLocalizedString(
                "relays.owner.knit",
                bundle: .main,
                value: "Knit's relay",
                comment: "Settings: marks the one relay the Knit project runs"
            )
        }

        /// The mark on every other relay.
        public static var notKnits: String {
            NSLocalizedString(
                "relays.owner.other",
                bundle: .main,
                value: "Not run by Knit",
                comment: "Settings: marks a relay someone other than the Knit project runs"
            )
        }

        /// The mark on a relay whose address carries a `k` key. It says only what the address carries: a relay without it may
        /// still need a secret of its own.
        public static var privateMark: String {
            NSLocalizedString(
                "relays.private",
                bundle: .main,
                value: "Access key in link",
                comment: "Settings: marks a relay whose link carries an access key; says nothing of relays without one"
            )
        }

        /// A relay whose socket is open (`relays_status_connected`).
        public static var connected: String {
            NSLocalizedString(
                "relays.status.connected",
                bundle: .main,
                value: "Connected",
                comment: "Settings: a relay's status, connected"
            )
        }

        /// A relay being dialled (`relays_status_connecting`).
        public static var connecting: String {
            NSLocalizedString(
                "relays.status.connecting",
                bundle: .main,
                value: "Connecting…",
                comment: "Settings: a relay's status, connecting"
            )
        }

        /// A relay waiting to be dialled again after failures.
        public static var waiting: String {
            NSLocalizedString(
                "relays.status.waiting",
                bundle: .main,
                value: "Waiting to try again",
                comment: "Settings: a relay's status, after tries that failed"
            )
        }

        /// A relay while the spool plane is paused.
        public static var paused: String {
            NSLocalizedString(
                "relays.status.paused",
                bundle: .main,
                value: "Paused",
                comment: "Settings: a relay's status while Knit's mesh is stopped"
            )
        }

        /// A relay the person stopped using (`relays_status_off`).
        public static var parked: String {
            NSLocalizedString(
                "relays.status.parked",
                bundle: .main,
                value: "Not in use",
                comment: "Settings: a relay's status after Stop using"
            )
        }

        /// A relay while the switch is off.
        public static var off: String {
            NSLocalizedString(
                "relays.status.off",
                bundle: .main,
                value: "Off",
                comment: "Settings: a relay's status while Internet relays are off"
            )
        }

        /// A relay whose address the Keychain could not read now.
        public static var unreadable: String {
            NSLocalizedString(
                "relays.status.unreadable",
                bundle: .main,
                value: "Can't read this relay right now",
                comment: "Settings: a relay's status when its address can't be read for now"
            )
        }

        /// A relay whose address item is gone.
        public static var missing: String {
            NSLocalizedString(
                "relays.status.missing",
                bundle: .main,
                value: "Its address is gone. Remove it and add its invite again.",
                comment: "Settings: a relay's status when its address is no longer on this phone"
            )
        }

        /// A relay whose stored address this build refuses.
        public static var unusable: String {
            NSLocalizedString(
                "relays.status.unusable",
                bundle: .main,
                value: "This build of Knit can't use this relay",
                comment: "Settings: a relay's status when this build refuses its address"
            )
        }

        /// The button that stops using a relay and keeps it listed.
        public static var park: String {
            NSLocalizedString(
                "relays.park",
                bundle: .main,
                value: "Stop using",
                comment: "Settings: keeps a relay in the list without connecting to it"
            )
        }

        /// The button that uses a parked relay again.
        public static var unpark: String {
            NSLocalizedString(
                "relays.unpark",
                bundle: .main,
                value: "Use again",
                comment: "Settings: starts using a relay the person stopped using"
            )
        }

        /// The button that removes a relay (`relays_remove`).
        public static var remove: String {
            NSLocalizedString(
                "relays.remove",
                bundle: .main,
                value: "Remove",
                comment: "Settings: removes a relay from the list"
            )
        }

        /// The header over Paste.
        public static var addHeader: String {
            NSLocalizedString(
                "relays.add.header",
                bundle: .main,
                value: "Add a relay",
                comment: "Settings: the header over the paste button that adds a relay"
            )
        }

        /// What Paste takes.
        public static var pasteFooter: String {
            NSLocalizedString(
                "relays.add.footer",
                bundle: .main,
                value: "Paste a relay invite link someone sent you.",
                comment: "Settings: below the paste button that adds a relay"
            )
        }

        /// The list with nothing in it.
        public static var empty: String {
            NSLocalizedString(
                "relays.empty",
                bundle: .main,
                value: "No relays in your list.",
                comment: "Settings: the relay list when it is empty"
            )
        }

        /// A relay listed twice: the other row is the one dialled.
        public static var duplicateRow: String {
            NSLocalizedString(
                "relays.status.duplicate",
                bundle: .main,
                value: "This relay is listed twice. Knit connects through the other row.",
                comment: "Settings: a relay's status when the same relay is in the list under another row"
            )
        }

        /// The section while the kept list cannot be read: nothing is dialled, and it is read again at each return.
        public static var listUnreadable: String {
            NSLocalizedString(
                "relays.list.unreadable",
                bundle: .main,
                value: "Knit can't read your relay list right now, so no relay is in use. It tries again each time you come back to Knit.",
                comment: "Settings: in place of the relay list when the kept list can't be read"
            )
        }

        /// A row whose address could not be read, by its number.
        public static func numbered(_ number: Int) -> String {
            format(
                NSLocalizedString(
                    "relays.numbered",
                    bundle: .main,
                    value: "Relay %d",
                    comment: "Settings: a relay whose address can't be read; %d is its number"
                ),
                number
            )
        }

        /// The list at its cap.
        public static func full(_ most: Int) -> String {
            format(
                NSLocalizedString(
                    "relays.refused.full",
                    bundle: .main,
                    value: "Your list already has %d relays, the most it can hold. Remove one to add another.",
                    comment: "Alert: the relay list is full; %d is the most relays it holds"
                ),
                most
            )
        }
    }
}
