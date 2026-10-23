import Foundation

/// The structural redaction a report's free text passes through before it is written (knit-next `CrashRedactor.kt`,
/// ADR 028). A report's frames are binaries and offsets and pass untouched; only the text the system wrote beside them
/// comes here: the termination reason, the memory region a bad access touched, and an Objective-C exception's name,
/// class and format string. The rules run in order, and each placeholder matches no rule, so redacting twice changes
/// nothing.
///
/// Android's second pass, over the contact names a phone knows, has no counterpart: MetricKit keeps no message an app
/// composed, and the collector drops an Objective-C exception's arguments, so nothing a person typed reaches a report.
public enum CrashRedactor {
    /// The longest a field is kept, in characters, after the rules.
    public static let maxFieldCharacters = 300

    private static let schemeGroup = 1
    private static let hostGroup = 2
    private static let pathGroup = 3

    private struct Rule {
        let pattern: NSRegularExpression
        let replace: @Sendable (_ text: String, _ match: NSTextCheckingResult) -> String
    }

    /// The rules, or `nil` if one failed to compile, which a test rules out.
    private static let rules: [Rule]? = {
        func rule(_ pattern: String, _ replace: @escaping @Sendable (String, NSTextCheckingResult) -> String) -> Rule? {
            (try? NSRegularExpression(pattern: pattern)).map { Rule(pattern: $0, replace: replace) }
        }
        func fixed(_ pattern: String, _ placeholder: String) -> Rule? {
            rule(pattern) { _, _ in placeholder }
        }
        let all = [
            fixed(#"\bfile://\S*"#, "file://[uri]"),
            // A web address keeps its scheme and host and loses the rest, a token in a query among it.
            rule(#"\b((?i:wss?|https?))://([A-Za-z0-9.\-:\[\]]+)(\S*)"#) { text, match in
                let scheme = group(match, schemeGroup, in: text)
                let host = group(match, hostGroup, in: text)
                return "\(scheme)://\(host)" + (group(match, pathGroup, in: text).isEmpty ? "" : "/[path]")
            },
            // The app's container path carries its per-install UUID; Android's rule names its own roots.
            fixed(#"(?<![\w/])/(?:private|var|Users|tmp)/\S*"#, "[path]"),
            fixed(#"\b\d{5}(?:\s+\d{5}){3,}\b"#, "[safety-number]"),
            fixed(#"\bg-[0-9a-f]{24}\b"#, "[group]"),
            // A node id: 26 characters of lowercase base32.
            fixed("(?<![a-z2-7])[a-z2-7]{26}(?![a-z2-7])", "[node]"),
            // A blob's hash, a device tag, a key.
            fixed(#"\b[0-9a-fA-F]{16,}\b"#, "[hex]"),
            // Base64 with a digit, a capital and a small letter in it: Android's rule without them also ate the long
            // selector names an Objective-C format string carries and the system's framework paths, which are the code's
            // own. Random base64 that long lacks a digit about once in sixty.
            fixed(#"\b(?=[A-Za-z0-9+/]*[0-9])(?=[A-Za-z0-9+/]*[a-z])(?=[A-Za-z0-9+/]*[A-Z])[A-Za-z0-9+/]{24,}={0,2}"#, "[b64]"),
            // A name or a message in any script but ASCII, the whole token.
            fixed(#"\S*[^\x00-\x7F]\S*"#, "[text]"),
        ]
        let compiled = all.compactMap(\.self)
        return compiled.count == all.count ? compiled : nil
    }()

    /// `text` with every rule applied and cut to ``maxFieldCharacters``, or `nil` when the rules are unavailable, in
    /// which case the field is withheld.
    public static func redact(_ text: String) -> String? {
        guard let rules else {
            return nil
        }
        let redacted = rules.reduce(text) { text, rule in apply(rule, to: text) }
        guard redacted.count > maxFieldCharacters else {
            return redacted
        }
        return "\(redacted.prefix(maxFieldCharacters))...(+\(redacted.count - maxFieldCharacters))"
    }

    private static func apply(_ rule: Rule, to text: String) -> String {
        var result = ""
        var last = text.startIndex
        let matches = rule.pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for (match, range) in matches.compactMap({ match in Range(match.range, in: text).map { (match, $0) } }) {
            result += text[last..<range.lowerBound]
            result += rule.replace(text, match)
            last = range.upperBound
        }
        return result + text[last...]
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String {
        Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
    }
}
