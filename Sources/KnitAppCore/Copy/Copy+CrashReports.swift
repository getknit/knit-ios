import Foundation

extension Copy {
    /// Saved crash and hang reports: Diagnostics' rows and a report's screen (ADR 2026-10.qhsv), after Android's crash
    /// log (`strings.xml`'s `crash_log_*`).
    public enum CrashReports {
        /// Diagnostics' section that holds the rows.
        public static var section: String {
            NSLocalizedString(
                "crash.section", bundle: .main, value: "Problem reports", comment: "Diagnostics: the section holding the saved reports")
        }

        /// The row, and the screen's title, for the newest crash.
        public static var lastCrash: String {
            NSLocalizedString("crash.last-crash", bundle: .main, value: "Last crash", comment: "Diagnostics: the newest saved crash report")
        }

        /// The row, and the screen's title, for the newest hang.
        public static var lastHang: String {
            NSLocalizedString(
                "crash.last-hang", bundle: .main, value: "Last hang", comment: "Diagnostics: the newest saved report of Knit not responding"
            )
        }

        /// The row or title for `kind`.
        public static func title(_ kind: CrashDiagnostic.Kind) -> String {
            kind == .crash ? lastCrash : lastHang
        }

        /// When a report was saved, as a relative time: "Saved 2 hours ago".
        public static func saved(_ when: String) -> String {
            format(
                NSLocalizedString(
                    "crash.saved",
                    bundle: .main,
                    value: "Saved %@",
                    comment: "Saved report: when it was saved; the argument is a relative time"
                ),
                when
            )
        }

        /// What the screen shows and where it stays.
        public static func explanation(_ kind: CrashDiagnostic.Kind) -> String {
            switch kind {
            case .crash:
                NSLocalizedString(
                    "crash.explanation",
                    bundle: .main,
                    value: """
                        Knit saved this the last time it closed unexpectedly. Nothing leaves this iPhone unless you copy, share or \
                        report it.
                        """,
                    comment: "Saved report: what a crash report is, and that it stays on the phone"
                )
            case .hang:
                NSLocalizedString(
                    "crash.explanation.hang",
                    bundle: .main,
                    value: """
                        Knit saved this the last time it stopped responding. Nothing leaves this iPhone unless you copy, share or \
                        report it.
                        """,
                    comment: "Saved report: what a hang report is, and that it stays on the phone"
                )
            }
        }

        /// What no report covers.
        public static var limits: String {
            NSLocalizedString(
                "crash.limits",
                bundle: .main,
                value: """
                    Some problems leave no report, such as iOS closing Knit to free memory. If Knit closed and nothing new appears \
                    here, describe what you were doing in a bug report instead.
                    """,
                comment: "Saved report: the failures it cannot capture"
            )
        }

        /// The screen once nothing is saved.
        public static var empty: String {
            NSLocalizedString(
                "crash.empty",
                bundle: .main,
                value: "No crash or hang reports are saved on this iPhone.",
                comment: "Saved report: none left"
            )
        }

        /// Opens the bug form.
        public static var report: String {
            NSLocalizedString("crash.report", bundle: .main, value: "Report on GitHub", comment: "Saved report: opens GitHub's bug form")
        }

        /// Copies the report.
        public static var copy: String {
            NSLocalizedString("crash.copy", bundle: .main, value: "Copy", comment: "Saved report: copies the report's text")
        }

        /// The copy button, just after a tap.
        public static var copied: String {
            NSLocalizedString("crash.copied", bundle: .main, value: "Copied", comment: "Saved report: the copy button once it has copied")
        }

        /// Shares the report as a file.
        public static var share: String {
            NSLocalizedString("crash.share", bundle: .main, value: "Share", comment: "Saved report: shares the report as a text file")
        }

        /// The section over the report's text.
        public static var details: String {
            NSLocalizedString("crash.details", bundle: .main, value: "Details", comment: "Saved report: the section holding its text")
        }

        /// Deletes every report, and confirms it.
        public static var deleteAll: String {
            NSLocalizedString("crash.delete", bundle: .main, value: "Delete all", comment: "Saved report: deletes every saved report")
        }

        /// The question before the bug form opens.
        public static var reportTitle: String {
            NSLocalizedString(
                "crash.report.title",
                bundle: .main,
                value: "Report this on GitHub?",
                comment: "Saved report: asks before opening the bug form"
            )
        }

        /// What opening the form does, and that what is posted there is public.
        public static var reportBody: String {
            NSLocalizedString(
                "crash.report.body",
                bundle: .main,
                value: """
                    Your browser opens a bug form with the details filled in, and the full report goes on your clipboard to paste \
                    in. GitHub issues are public, so read it over first. The report holds no names or messages, and Knit has taken \
                    IDs out of it.
                    """,
                comment: "Saved report: what Report on GitHub does, and that the issue is public"
            )
        }

        /// Opens the form.
        public static var openForm: String {
            NSLocalizedString("crash.report.open", bundle: .main, value: "Open the form", comment: "Saved report: opens the bug form")
        }

        /// The question before every report is deleted.
        public static var deleteTitle: String {
            NSLocalizedString(
                "crash.delete.title",
                bundle: .main,
                value: "Delete saved reports?",
                comment: "Saved report: asks before deleting every report"
            )
        }

        /// What deleting does.
        public static var deleteBody: String {
            NSLocalizedString(
                "crash.delete.body",
                bundle: .main,
                value: "This deletes every crash and hang report saved on this iPhone. You can't undo it.",
                comment: "Saved report: what Delete all does"
            )
        }

        /// The share sheet's title for the file.
        public static func shareTitle(_ kind: CrashDiagnostic.Kind) -> String {
            switch kind {
            case .crash:
                NSLocalizedString(
                    "crash.share.title", bundle: .main, value: "Knit crash report", comment: "Saved report: the shared file's title")
            case .hang:
                NSLocalizedString(
                    "crash.share.title.hang", bundle: .main, value: "Knit hang report", comment: "Saved report: the shared file's title")
            }
        }
    }
}
