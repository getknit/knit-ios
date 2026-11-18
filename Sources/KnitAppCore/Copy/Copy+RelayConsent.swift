import Foundation

extension Copy {
    /// Internet relays' consent sheets and refusals (ADR 2026-11.adrq, P6), apart from ``Relays`` only to keep each file under
    /// the lint's length. No string names any part of a link.
    public enum RelayConsent {
        /// The switch's consent sheet's title (`relays_consent_title`).
        public static var turnOnTitle: String {
            NSLocalizedString(
                "relays.consent.title",
                bundle: .main,
                value: "Use Internet relays?",
                comment: "Consent sheet: the title of the sheet that turns Internet relays on"
            )
        }

        /// Under a relay the switch's sheet names by number: it joins once its address reads.
        public static var joinsOnceRead: String {
            NSLocalizedString(
                "relays.consent.later",
                bundle: .main,
                value: "Joins once Knit can read its address",
                comment: "Consent sheet: under a relay whose address can't be read right now, shown by its number"
            )
        }

        /// The consent could not be kept, so the switch stays off.
        public static var consentNotSaved: String {
            NSLocalizedString(
                "relays.refused.consent",
                bundle: .main,
                value: "Knit couldn't turn relays on. Try again.",
                comment: "Alert: the consent to Internet relays couldn't be saved, so they stay off"
            )
        }

        /// What introduces the hosts the switch dials.
        public static var turnOnHosts: String {
            NSLocalizedString(
                "relays.consent.hosts",
                bundle: .main,
                value: "Knit connects to these relays:",
                comment: "Consent sheet: introduces the list of relays turning relays on connects to"
            )
        }

        /// What the switch's sheet says when it dials nothing.
        public static var turnOnNone: String {
            NSLocalizedString(
                "relays.consent.none",
                bundle: .main,
                value: "Your list has no relays yet. Add one from its invite link.",
                comment: "Consent sheet: when turning relays on connects to no relay yet"
            )
        }

        /// What a relay learns (ADR 2026-11.adrq, P6).
        public static var learns: String {
            NSLocalizedString(
                "relays.consent.learns",
                bundle: .main,
                value: """
                    Whoever runs a relay sees a code for each conversation you have with your contacts, when messages move, when \
                    Knit is open, and your phone's IP address. It can't read your messages.
                    """,
                comment: "Consent sheet: what a relay learns, and that it can't read messages"
            )
        }

        /// What rides a relay.
        public static var textOnly: String {
            NSLocalizedString(
                "relays.consent.text",
                bundle: .main,
                value: """
                    Relays carry text messages with your contacts. Photos, voice messages, groups and the Nearby room travel \
                    over Bluetooth.
                    """,
                comment: "Consent sheet: what relays carry and what stays on Bluetooth"
            )
        }

        /// The boundary: only while Knit is open.
        public static var openOnly: String {
            NSLocalizedString(
                "relays.consent.open",
                bundle: .main,
                value: """
                    Relays run only while Knit is open. A message that comes through a relay while Knit is closed arrives the \
                    next time you open it.
                    """,
                comment: "Consent sheet: relays run only while Knit is open"
            )
        }

        /// The switch sheet's button (`relays_consent_accept`).
        public static var turnOn: String {
            NSLocalizedString(
                "relays.consent.accept",
                bundle: .main,
                value: "Turn on",
                comment: "Consent sheet: turns Internet relays on"
            )
        }

        /// Closes a consent sheet (`relays_consent_decline`).
        public static var notNow: String {
            NSLocalizedString(
                "relays.consent.decline",
                bundle: .main,
                value: "Not now",
                comment: "Consent sheet: closes the sheet without changing anything"
            )
        }

        /// The invite's sheet's title.
        public static var addTitle: String {
            NSLocalizedString(
                "relays.invite.title",
                bundle: .main,
                value: "Add this relay?",
                comment: "Consent sheet: the title of the sheet a relay invite opens"
            )
        }

        /// What the invite's sheet says of a relay whose link carries an access key (`relays_invite_private`).
        public static var privateNote: String {
            NSLocalizedString(
                "relays.invite.private",
                bundle: .main,
                value: "This relay's link carries its access key, so anyone with the link can use it.",
                comment: "Consent sheet: the invite's relay has an access key in its link"
            )
        }

        /// What the invite's sheet says while the switch is off.
        public static var offNote: String {
            NSLocalizedString(
                "relays.invite.off",
                bundle: .main,
                value: "Internet relays are off. Knit adds this relay to your list and connects once you turn relays on in Settings.",
                comment: "Consent sheet: adding a relay while Internet relays are off"
            )
        }

        /// The invite's sheet's button (`relays_invite_confirm_add`).
        public static var add: String {
            NSLocalizedString(
                "relays.invite.add",
                bundle: .main,
                value: "Add relay",
                comment: "Consent sheet: adds the invite's relay"
            )
        }

        /// The title over a refusal (`relays_invite_title`).
        public static var inviteAlert: String {
            NSLocalizedString(
                "relays.invite.alert",
                bundle: .main,
                value: "Relay invite",
                comment: "Alert: the title over why a relay invite wasn't added"
            )
        }

        /// A link that is no invite (`relays_invite_refused`).
        public static var notAnInvite: String {
            NSLocalizedString(
                "relays.refused.invite",
                bundle: .main,
                value: "This link isn't a relay invite Knit can read.",
                comment: "Alert: a link that is no relay invite Knit reads"
            )
        }

        /// An invite for an address this build will not dial (`relays_invite_refused_url`).
        public static var unusableInvite: String {
            NSLocalizedString(
                "relays.refused.address",
                bundle: .main,
                value: "This invite points to a relay Knit can't connect to.",
                comment: "Alert: a relay invite for an address Knit won't connect to"
            )
        }

        /// An invite for a relay already listed (`relays_invite_already`).
        public static var duplicate: String {
            NSLocalizedString(
                "relays.refused.duplicate",
                bundle: .main,
                value: "This relay is already in your list.",
                comment: "Alert: a relay invite for a relay already listed"
            )
        }

        /// The list not read yet.
        public static var listUnavailable: String {
            NSLocalizedString(
                "relays.refused.unavailable",
                bundle: .main,
                value: "Knit can't read your relay list right now. Try again in a moment.",
                comment: "Alert: the relay list couldn't be read yet"
            )
        }

        /// An address the store would not keep.
        public static var notSaved: String {
            NSLocalizedString(
                "relays.refused.save",
                bundle: .main,
                value: "Knit couldn't save this relay. Try again.",
                comment: "Alert: a relay's address couldn't be kept"
            )
        }
    }
}
