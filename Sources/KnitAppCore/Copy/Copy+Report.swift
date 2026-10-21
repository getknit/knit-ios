import Foundation

extension Copy {
    /// Reporting someone (ADR 2026-10.f6kf): from a message's menu, their profile or their request. A report deletes the
    /// message and blocks the person on this phone, and can go to Knit by email. The person is never told.
    public enum Report {
        /// The button that reports, in a menu, on a request and in the confirmation.
        public static var report: String {
            NSLocalizedString("report.report", bundle: .main, value: "Report", comment: "Report: the button that reports someone")
        }

        /// The profile's button that reports the person.
        public static func reportPerson(_ name: String) -> String {
            format(
                NSLocalizedString(
                    "report.report-person",
                    bundle: .main,
                    value: "Report %@",
                    comment: "Profile: reports the person; %@ is their name"
                ),
                name
            )
        }

        /// The confirmation's title.
        public static func confirmTitle(_ name: String) -> String {
            format(
                NSLocalizedString(
                    "report.confirm.title",
                    bundle: .main,
                    value: "Report %@?",
                    comment: "Report: the confirmation's title; %@ is the person's name"
                ),
                name
            )
        }

        /// What reporting a message does, in the confirmation.
        public static func confirmMessage(_ name: String) -> String {
            format(
                NSLocalizedString(
                    "report.confirm.message",
                    bundle: .main,
                    value: """
                        Knit deletes this message from your phone and blocks %@, and doesn't tell them. Email the report \
                        too, and the Knit team will read it within 24 hours.
                        """,
                    comment: "Report: what reporting a message does, in the confirmation; %@ is the person's name"
                ),
                name
            )
        }

        /// What reporting a person does, in the confirmation.
        public static func confirmPerson(_ name: String) -> String {
            format(
                NSLocalizedString(
                    "report.confirm.person",
                    bundle: .main,
                    value: """
                        Knit blocks %@ on your phone and doesn't tell them. Email the report too, and the Knit team will \
                        read it within 24 hours.
                        """,
                    comment: "Report: what reporting a person does, in the confirmation; %@ is the person's name"
                ),
                name
            )
        }

        /// The confirmation's button that reports and then opens the email.
        public static var reportAndEmail: String {
            NSLocalizedString(
                "report.report-and-email",
                bundle: .main,
                value: "Report and Email Knit",
                comment: "Report: the confirmation's button that reports, then opens an email to Knit"
            )
        }

        /// The alert's title when this phone cannot send email.
        public static var noMailTitle: String {
            NSLocalizedString(
                "report.no-mail.title",
                bundle: .main,
                value: "Can't Open Email",
                comment: "Report: the alert's title when the phone has no way to send email"
            )
        }

        /// What the user can do instead, when this phone cannot send email.
        public static func noMailBody(_ address: String) -> String {
            format(
                NSLocalizedString(
                    "report.no-mail.body",
                    bundle: .main,
                    value: "Your report is done on this phone. To send it to the Knit team, email %@ from any device.",
                    comment: "Report: when the phone cannot send email; %@ is Knit's report address"
                ),
                address
            )
        }

        /// The button that copies the address.
        public static var copyAddress: String {
            NSLocalizedString(
                "report.copy-address",
                bundle: .main,
                value: "Copy Address",
                comment: "Report: copies Knit's report address"
            )
        }

        // MARK: The email

        /// The email's subject.
        public static func emailSubject(_ name: String) -> String {
            format(
                NSLocalizedString(
                    "report.email.subject",
                    bundle: .main,
                    value: "Knit report: %@",
                    comment: "Report email: the subject; %@ is the reported person's name"
                ),
                name
            )
        }

        /// The email's first line.
        public static func emailIntro(version: String, at time: String) -> String {
            format(
                NSLocalizedString(
                    "report.email.intro",
                    bundle: .main,
                    value: "Reported from Knit %1$@ for iPhone at %2$@.",
                    comment: "Report email: the first line; %1$@ is the app's version, %2$@ the time, in ISO 8601"
                ),
                version,
                time
            )
        }

        /// Who is reported.
        public static func emailPerson(_ name: String) -> String {
            format(
                NSLocalizedString("report.email.person", bundle: .main, value: "Person: %@", comment: "Report email: the person's name"),
                name
            )
        }

        /// Their node id.
        public static func emailNodeId(_ nodeId: String) -> String {
            format(
                NSLocalizedString(
                    "report.email.node-id", bundle: .main, value: "Node ID: %@", comment: "Report email: the person's node id"),
                nodeId
            )
        }

        /// Where the user met it.
        public static func emailPlace(_ place: AbuseReport.Place) -> String {
            let template = NSLocalizedString(
                "report.email.place",
                bundle: .main,
                value: "Where: %@",
                comment: "Report email: where it happened; %@ is Nearby, a direct message, a group, a request or a profile"
            )
            return format(template, placeName(place))
        }

        /// When the message was sent.
        public static func emailSent(_ time: String) -> String {
            format(
                NSLocalizedString(
                    "report.email.sent",
                    bundle: .main,
                    value: "Sent: %@",
                    comment: "Report email: when the message was sent, by the sender's clock, in ISO 8601"
                ),
                time
            )
        }

        /// Their status line.
        public static func emailStatus(_ status: String) -> String {
            format(
                NSLocalizedString(
                    "report.email.status", bundle: .main, value: "Status: %@", comment: "Report email: the person's status line"),
                status
            )
        }

        /// The heading over the message's words.
        public static var emailMessage: String {
            NSLocalizedString("report.email.message", bundle: .main, value: "Message:", comment: "Report email: over the message's words")
        }

        /// In place of the words, for a photo sent alone.
        public static var emailNoWords: String {
            NSLocalizedString(
                "report.email.no-words",
                bundle: .main,
                value: "(No text)",
                comment: "Report email: in place of the message's words, for a photo with none"
            )
        }

        /// Under the words, for a message with a photo.
        public static var emailPhoto: String {
            NSLocalizedString(
                "report.email.photo",
                bundle: .main,
                value: "(The message had a photo. Knit doesn't attach photos to reports.)",
                comment: "Report email: under the words of a message that carried a photo"
            )
        }

        /// The last line, over room for the user's own words.
        public static var emailAddMore: String {
            NSLocalizedString(
                "report.email.add-more",
                bundle: .main,
                value: "Anything else we should know:",
                comment: "Report email: over room for the reporter's own words"
            )
        }

        /// Where, in a word or two.
        private static func placeName(_ place: AbuseReport.Place) -> String {
            switch place {
            case .room:
                NSLocalizedString("report.email.place.room", bundle: .main, value: "Nearby", comment: "Report email: the Nearby room")
            case .direct:
                NSLocalizedString("report.email.place.direct", bundle: .main, value: "Direct message", comment: "Report email: a DM")
            case .group(let title):
                format(
                    NSLocalizedString(
                        "report.email.place.group",
                        bundle: .main,
                        value: "Group \"%@\"",
                        comment: "Report email: a group; %@ is its title"
                    ),
                    title
                )
            case .request:
                NSLocalizedString("report.email.place.request", bundle: .main, value: "Message request", comment: "Report email: a request")
            case .profile:
                NSLocalizedString("report.email.place.profile", bundle: .main, value: "Profile", comment: "Report email: their profile")
            }
        }
    }
}
