import Foundation

extension Copy {
    /// Settings: the mesh's Stop and Start, notifications, and the ways to About and Diagnostics.
    public enum Settings {
        /// The screen's title.
        public static var title: String {
            NSLocalizedString("settings.title", bundle: .main, value: "Settings", comment: "Settings: the screen's title")
        }

        /// The mesh section.
        public static var meshSection: String {
            NSLocalizedString("settings.mesh", bundle: .main, value: "Mesh", comment: "Settings: the section with Stop and Start")
        }

        /// The button that stops the mesh.
        public static var stop: String {
            NSLocalizedString("settings.stop", bundle: .main, value: "Stop mesh", comment: "Settings: stops the mesh")
        }

        /// The button that starts it again.
        public static var start: String {
            NSLocalizedString("settings.start", bundle: .main, value: "Start mesh", comment: "Settings: starts the mesh")
        }

        /// What stopping costs, short, under the button; ``meshInfo`` holds the rest.
        public static var stopFooter: String {
            NSLocalizedString(
                "settings.stop.footer.short",
                bundle: .main,
                value: "Messages you write while the mesh is stopped wait on this iPhone.",
                comment: "Settings: under Stop mesh, what happens to messages while it is stopped"
            )
        }

        /// The info button beside Stop and Start, and the title of the sheet it opens.
        public static var meshInfo: String {
            NSLocalizedString(
                "settings.mesh.info",
                bundle: .main,
                value: "About the mesh",
                comment: "Settings: the info button beside Stop mesh, and the title of the sheet it opens"
            )
        }

        /// What stopping does, in full, first in ``meshInfo``'s sheet.
        public static var stopDetail: String {
            NSLocalizedString(
                "settings.stop.footer",
                bundle: .main,
                value: """
                    Stopping closes every link and stops looking for people. Messages you write meanwhile wait on this iPhone until you \
                    start again.
                    """,
                comment: "Settings: what stopping the mesh does"
            )
        }

        /// The notifications row.
        public static var notifications: String {
            NSLocalizedString("settings.notifications", bundle: .main, value: "Notifications", comment: "Settings: the notifications row")
        }

        /// Notifications are allowed.
        public static var notificationsOn: String {
            NSLocalizedString("settings.notifications.on", bundle: .main, value: "On", comment: "Settings: notifications are allowed")
        }

        /// Notifications have not been asked for yet.
        public static var notificationsAsk: String {
            NSLocalizedString(
                "settings.notifications.ask",
                bundle: .main,
                value: "Turn On",
                comment: "Settings: button that asks for notifications"
            )
        }

        /// Notifications were refused.
        public static var notificationsOff: String {
            NSLocalizedString("settings.notifications.off", bundle: .main, value: "Off", comment: "Settings: notifications are refused")
        }

        /// What notifications are for.
        public static var notificationsFooter: String {
            NSLocalizedString(
                "settings.notifications.footer.short",
                bundle: .main,
                value: "Hear about messages that arrive while Knit is in the background.",
                comment: "Settings: what notifications are for"
            )
        }

        /// The row that emails Knit's report address, at the top level so App Review finds the contact guideline 1.2
        /// asks for (ADR 2026-10.tydq).
        public static var reportProblem: String {
            NSLocalizedString(
                "settings.report-problem",
                bundle: .main,
                value: "Report a problem",
                comment: "Settings: the row that opens an email to Knit's report address"
            )
        }

        /// Under Blocked people, Report a problem and the terms: where to report someone, and how to reach Knit.
        public static func safetyFooter(_ address: String) -> String {
            format(
                NSLocalizedString(
                    "settings.safety.footer",
                    bundle: .main,
                    value: """
                        Report someone from their message's menu or their profile. To reach the Knit team, email %@. The team \
                        reads every emailed report within 24 hours.
                        """,
                    comment: "Settings: under the safety rows; %@ is Knit's report address"
                ),
                address
            )
        }

        /// The row that opens About.
        public static var about: String {
            NSLocalizedString("settings.about", bundle: .main, value: "About", comment: "Settings: the row that opens About")
        }

        /// The row that opens Diagnostics.
        public static var diagnostics: String {
            NSLocalizedString(
                "settings.diagnostics",
                bundle: .main,
                value: "Diagnostics",
                comment: "Settings: the row that opens Diagnostics"
            )
        }
    }

    /// About: the licence notice, the source and the notices of what ships inside.
    public enum About {
        /// The screen's title.
        public static var title: String {
            NSLocalizedString("about.title", bundle: .main, value: "About", comment: "About: the screen's title")
        }

        /// The version row: "Version 0.1.0 (1)".
        public static func version(_ version: String, build: String) -> String {
            format(
                NSLocalizedString(
                    "about.version",
                    bundle: .main,
                    value: "Version %1$@ (%2$@)",
                    comment: "About: %1$@ is the version, such as 0.1.0, and %2$@ the build number"
                ),
                version,
                build
            )
        }

        /// The licence notice. It states the licence rather than paraphrasing it, so it is not edited for tone.
        public static var license: String {
            NSLocalizedString(
                "about.license",
                bundle: .main,
                value: """
                    Knit is free software, released under the GNU General Public License, version 3 or later, with an additional \
                    permission for app stores. It comes with no warranty.
                    """,
                comment: "About: the licence notice"
            )
        }

        /// The source code row.
        public static var source: String {
            NSLocalizedString("about.source", bundle: .main, value: "Source code", comment: "About: the row that opens the source code")
        }

        /// The row that emails Knit, the contact App Store rule 1.2 asks for (ADR 2026-10.f6kf).
        public static var contact: String {
            NSLocalizedString("about.contact", bundle: .main, value: "Email Knit", comment: "About: the row that emails Knit")
        }

        /// The row that opens the privacy policy, which App Store rule 5.1.1(i) asks the app to link.
        public static var privacy: String {
            NSLocalizedString(
                "about.privacy", bundle: .main, value: "Privacy policy", comment: "About: the row that opens the privacy policy")
        }

        /// The row that lists the open-source components inside Knit.
        public static var notices: String {
            NSLocalizedString(
                "about.notices",
                bundle: .main,
                value: "Open-source licenses",
                comment: "About: the row listing bundled components"
            )
        }

        /// What protects what, scoped (`.agents/rules/copy.md`).
        public static var security: String {
            NSLocalizedString(
                "about.security",
                bundle: .main,
                value: """
                    Direct messages are end-to-end encrypted. The Nearby room is open to everyone in range. The Bluetooth links between \
                    phones aren't encrypted themselves, so anyone listening can see public posts and who each direct message is from and \
                    to, but not what it says.
                    """,
                comment: "About: what encryption covers"
            )
        }
    }
}
