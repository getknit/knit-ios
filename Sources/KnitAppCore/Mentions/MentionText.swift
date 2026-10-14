public import KnitStore
import KnitWire

/// The "@" word the cursor sits in, which the picker narrows by (`MentionQuery` in knit-next's `MentionText.kt`). Every
/// offset counts UTF-16 code units, as Kotlin's do and as a text view's ranges do.
public struct MentionQuery: Sendable, Equatable {
    /// Where the "@" is.
    public var start: Int
    /// The cursor, just past the query.
    public var end: Int
    /// What lies between the "@" and the cursor: "Joy" for "@Joy|".
    public var query: String

    /// A query.
    public init(start: Int, end: Int, query: String) {
        self.start = start
        self.end = end
        self.query = query
    }
}

/// One replacement in the text as it stood before an edit: its UTF-16 `range` became `text` (`MentionEdit`).
public struct MentionEdit: Sendable, Equatable {
    /// The part of the old text replaced.
    public var range: Range<Int>
    /// What replaced it.
    public var text: String

    /// An edit.
    public init(range: Range<Int>, text: String) {
        self.range = range
        self.text = text
    }
}

/// Android's mention rules, as `MentionText.kt` writes them (ADR 2026-10.nbhj): where the picker opens and whom it
/// offers, where a thread's names are highlighted, and how the composer keeps a picked name whole (knit-next
/// `d47ad76c`, after the pin, and UI only). Each works in UTF-16 offsets.
public enum MentionText {
    /// The "@" word the cursor sits in, or `nil` (`activeMentionQuery`, `MentionText.kt:32-49`). The word starts at an
    /// "@" at the start of the text or just after whitespace, as Kotlin's `isWhitespace` reads it on ART (ADR
    /// 2026-10.7uyt), and runs to the cursor; whitespace between them ends it. The nearest "@" before the cursor wins, and
    /// one inside a word, as in an email address, never opens the picker.
    public static func activeQuery(in text: String, cursor: Int) -> MentionQuery? {
        let units = Array(text.utf16)
        guard cursor >= 0, cursor <= units.count else {
            return nil
        }
        var index = cursor - 1
        while index >= 0 {
            let unit = units[index]
            if unit == at {
                guard index == 0 || isWhitespace(units[index - 1]) else {
                    return nil
                }
                return MentionQuery(start: index, end: cursor, query: String(decoding: units[(index + 1)..<cursor], as: UTF16.self))
            }
            if isWhitespace(unit) {
                return nil
            }
            index -= 1
        }
        return nil
    }

    /// The people `query` names (`filterCandidates`, `MentionText.kt:57-73`): those whose label or alias, lowercased and
    /// with its spaces taken out, holds the query, lowercased and trimmed. A query never holds a space, and a grown
    /// alias does, so "@joyfulferret" finds "Joyful Ferret". A blank query offers everyone.
    public static func filter(_ candidates: [MentionCandidate], query: String) -> [MentionCandidate] {
        let wanted = Array(TextLimits.trimmed(query).lowercased().utf16)
        guard !wanted.isEmpty else {
            return candidates
        }
        func holds(_ text: String) -> Bool {
            // Kotlin's `replace(" ", "")` takes out U+0020 alone, scalar by scalar.
            let spaceless = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != " " }))
            return TextLimits.utf16Index(of: wanted, in: Array(spaceless.lowercased().utf16)) != nil
        }
        return candidates.filter { holds($0.label.text) || holds($0.label.alias) }
    }

    /// Where each of `mentions` sits in `text`, sorted by start (`mentionSpans`, `MentionText.kt:94-119`): every
    /// occurrence of each token, longest token first, so "@Jay" never takes the front of "@Jaylene" and no two spans
    /// overlap. The match is by code units, with no word boundary, as on Android: a mention of "Coral" also lights the
    /// "@Coral" in "@Coralie". One rule for a bubble's highlight and the composer's chips, so the two agree.
    public static func spans(in text: String, mentions: [MessageMention]) -> [Range<Int>] {
        let units = Array(text.utf16)
        guard !mentions.isEmpty, !units.isEmpty else {
            return []
        }
        var tokens: [[UInt16]] = []
        for mention in mentions where !mention.name.isEmpty {
            let token = Array(mention.token.utf16)
            if !tokens.contains(token) {
                tokens.append(token)
            }
        }
        var taken = [Bool](repeating: false, count: units.count)
        var spans: [Range<Int>] = []
        // Longest first, and tokens of one length in their first order, as Kotlin's stable `sortedByDescending` leaves them.
        let longestFirst = tokens.enumerated().sorted { first, second in
            first.element.count != second.element.count ? first.element.count > second.element.count : first.offset < second.offset
        }
        for token in longestFirst.map(\.element) {
            var from = TextLimits.utf16Index(of: token, in: units)
            while let start = from {
                let span = start..<(start + token.count)
                if !span.contains(where: { taken[$0] }) {
                    spans.append(span)
                    for index in span {
                        taken[index] = true
                    }
                }
                from = TextLimits.utf16Index(of: token, in: units, from: start + 1)
            }
        }
        return spans.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// `edits`, offsets in the text before them, widened so none cuts into one of `chips` (`keepChipsWhole`,
    /// `MentionText.kt:134-168`). An edit that removes or replaces any part of a chip takes the whole chip, so one
    /// backspace at "@Walter|" deletes "@Walter", and an insertion strictly inside one moves to its end. Edits the
    /// widening makes meet are merged. `nil` when every edit already leaves every chip whole or wholly gone, so the
    /// caller keeps the edit as it came.
    public static func keepChipsWhole(_ chips: [Range<Int>], edits: [MentionEdit]) -> [MentionEdit]? {
        var widened = false
        let moved = edits.map { edit in
            var start = edit.range.lowerBound
            var end = edit.range.upperBound
            for chip in chips {
                if start == end {
                    if chip.lowerBound < start, start < chip.upperBound {
                        start = chip.upperBound
                        end = chip.upperBound
                    }
                } else if start < chip.upperBound, chip.lowerBound < end {
                    start = min(start, chip.lowerBound)
                    end = max(end, chip.upperBound)
                }
            }
            if start != edit.range.lowerBound || end != edit.range.upperBound {
                widened = true
            }
            return MentionEdit(range: start..<end, text: edit.text)
        }
        guard widened else {
            return nil
        }
        var merged: [MentionEdit] = []
        for edit in moved.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            if let previous = merged.last, edit.range.lowerBound <= previous.range.upperBound {
                merged[merged.count - 1] = MentionEdit(
                    range: previous.range.lowerBound..<max(previous.range.upperBound, edit.range.upperBound),
                    text: previous.text + edit.text
                )
            } else {
                merged.append(edit)
            }
        }
        return merged
    }

    /// `selection` moved out of the inside of any of `chips` (`snapOutOfChips`, `MentionText.kt:176-196`). A cursor that
    /// stepped in from a chip's edge, `from` being the cursor before a move that changed no text, crosses to the other
    /// edge, so the arrow keys step over a chip. Any other cursor goes to the nearer edge, the end on a tie. A range grows
    /// to take every chip it cuts, so a cut or a paste over it never leaves half a name. A text view's selection has no
    /// direction, so Android's reversed range has nothing to keep here.
    public static func snapOutOfChips(_ chips: [Range<Int>], selection: Range<Int>, from: Range<Int>?) -> Range<Int> {
        func inside(_ offset: Int) -> Range<Int>? {
            chips.first { $0.lowerBound < offset && offset < $0.upperBound }
        }
        guard selection.isEmpty else {
            let lower = inside(selection.lowerBound)?.lowerBound ?? selection.lowerBound
            let upper = inside(selection.upperBound)?.upperBound ?? selection.upperBound
            return lower..<upper
        }
        let cursor = selection.lowerBound
        guard let chip = inside(cursor) else {
            return selection
        }
        let edge: Int
        if let from, from.isEmpty, from.lowerBound == chip.upperBound {
            edge = chip.lowerBound
        } else if let from, from.isEmpty, from.lowerBound == chip.lowerBound {
            edge = chip.upperBound
        } else if cursor - chip.lowerBound < chip.upperBound - cursor {
            edge = chip.lowerBound
        } else {
            edge = chip.upperBound
        }
        return edge..<edge
    }

    /// `text` with the UTF-16 `range` replaced by `replacement` as ``keepChipsWhole(_:edits:)`` widens it, and the cursor
    /// just past what replaced it (`MentionChips.transformInput`, `MentionText.kt:208-226`), or `nil` when the edit leaves
    /// every chip whole and the field applies it as it came.
    public static func edited(
        _ text: String, chips: [Range<Int>], replacing range: Range<Int>, with replacement: String
    ) -> (text: String, cursor: Int)? {
        // One edit in widens to one edit out: the field reports a single replacement at a time.
        guard let widened = keepChipsWhole(chips, edits: [MentionEdit(range: range, text: replacement)])?.first else {
            return nil
        }
        var units = Array(text.utf16)
        let lower = min(widened.range.lowerBound, units.count)
        units.replaceSubrange(lower..<min(widened.range.upperBound, units.count), with: Array(widened.text.utf16))
        return (String(decoding: units, as: UTF16.self), lower + widened.text.utf16.count)
    }

    /// The text the composer inserts for a pick: "@", the label, and a space, which closes the query.
    public static func insertion(for candidate: MentionCandidate) -> String {
        "@" + candidate.label.text + " "
    }

    /// "@" as a code unit.
    private static let at = UInt16(UInt8(ascii: "@"))

    /// Kotlin's `Char.isWhitespace` on one code unit: a half of a surrogate pair never is.
    private static func isWhitespace(_ unit: UInt16) -> Bool {
        Unicode.Scalar(unit).map(TextLimits.isKotlinWhitespace) ?? false
    }
}
