public import Foundation

/// The link to Knit for iOS's own bug form, filled in from a saved report (knit-next `CrashIssueUrl.kt`, ADR
/// 2026-10.qhsv). Knit never posts anything: this is a link, the user's browser opens the form, and the user submits it,
/// so there is no token, no API call and nothing sent on its own.
///
/// The query's keys are the `id`s of `.github/ISSUE_TEMPLATE/bug_report.yml`'s fields. That file and this one are a
/// contract, which `CrashIssueURLTests` reads the template to hold.
///
/// **Steps to reproduce and What you expected stay blank.** The form requires both, so GitHub refuses the issue until
/// the reporter writes them: everything the iPhone knows arrives filled in, and the two things only a person knows stay
/// theirs to write.
public enum CrashIssueURL {
    /// Where a new issue is opened.
    public static let issues = AboutInfo.sourceURL + "/issues/new"
    /// GitHub refuses a prefilled link much past 8 KB. Percent-encoding roughly triples a report, so the excerpt is
    /// fitted against the encoded length.
    public static let maxURLCharacters = 7000
    /// Marks an issue the app filled in, for a triage workflow to find, as Android's does.
    public static let marker = "<!-- knit-crash-report -->"
    /// The form.
    static let template = "bug_report.yml"
    /// The form's "Where Knit was on the iPhone": nobody knows for a report the phone saved, so the reporter narrows it.
    static let stateUnknown = "Not sure"
    static let truncated = "... truncated, the full report is on your clipboard"

    /// The form's link for `ref`, carrying as much of its `text` as fits, or `nil` when no link can be made.
    public static func forReport(_ ref: CrashReportRef, text: String, issues: String = issues) -> URL? {
        let crash = ref.kind == .crash
        let fixed = [
            ("template", template),
            ("title", "[Bug]: \(crash ? "Crash" : "Hang") - \(ref.summary)"),
            (
                "summary",
                crash
                    ? "Knit closed unexpectedly. The iPhone saved the details, and they're below."
                    : "Knit stopped responding. The iPhone saved the details, and they're below."
            ),
            (
                "actual",
                crash
                    ? "Knit crashed. The report is under \"Logs or screenshots\"."
                    : "Knit stopped responding for a while. The report is under \"Logs or screenshots\"."
            ),
            ("version", ref.version),
            ("devices", [ref.device, ref.system, "Knit \(ref.version)"].filter { !$0.isEmpty }.joined(separator: ", ")),
            ("state", stateUnknown),
        ]
        let excerpt = fit(text, budget: maxURLCharacters - build(issues, fixed + [("logs", logs(""))]).count)
        return URL(string: build(issues, fixed + [("logs", logs(excerpt))]))
    }

    /// The query. Blank values are dropped, so the form shows its own placeholder. A Swift string always encodes, so
    /// no value is lost to a failed one.
    static func build(_ issues: String, _ fields: [(String, String)]) -> String {
        let pairs = fields.compactMap { key, value in value.isEmpty ? nil : QueryValue.encoded(value).map { "\(key)=\($0)" } }
        return issues + "?" + pairs.joined(separator: "&")
    }

    private static func logs(_ excerpt: String) -> String {
        """
        \(marker)
        Saved by Knit on the iPhone and redacted before it left the phone.
        The full report is on your clipboard. Paste it below in place of this excerpt.

        ```text
        \(excerpt)
        ```

        """
    }

    /// The longest run of whole lines from the start of `text` whose encoded form fits in `budget`, so the header and
    /// the attributed thread survive and no frame is cut in half.
    static func fit(_ text: String, budget: Int) -> String {
        // A line that cannot be encoded costs more than the budget, so the excerpt ends where it stands.
        let cost = { (part: Substring) in QueryValue.encoded(part)?.count ?? budget + 1 }
        guard budget > 0 else {
            return truncated
        }
        if cost(Substring(text)) <= budget {
            return text
        }
        let tail = "\n" + truncated
        let newline = cost("\n")
        var spent = cost(Substring(tail))
        var kept: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let next = cost(line) + (kept.isEmpty ? 0 : newline)
            guard spent + next <= budget else {
                break
            }
            kept.append(line)
            spent += next
        }
        return kept.isEmpty ? truncated : kept.joined(separator: "\n") + tail
    }
}
