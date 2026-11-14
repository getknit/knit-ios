import Foundation
import KnitWire

/// The room's word list, the first and cheapest pass over a Nearby message (`LexicalTextFilter.kt`, ADR 2026-10.e4kz).
/// Only the room runs it: profanity among people who chose each other is theirs to allow (`ScopedTextModerator`).
///
/// It sees through what a plain list misses, as Android's does:
/// - **case, accents and look-alikes:** lowercased, then NFKD with the marks dropped, so `SHÍT` and `ＦＵＣＫ` fold;
/// - **leetspeak:** digits and symbols read as the letters they stand for, so `sh1t` and `$h!t` are `shit`;
/// - **stretched letters:** a run of three or more becomes one, so `shiiit` is `shit`, while `ass` keeps its pair;
/// - **spaced letters:** single letters in a row join, so `f u c k` and `f.u.c.k` are `fuck`.
///
/// It matches whole words, never parts of one, so *class*, *assistant* and *Scunthorpe* pass. What a list cannot
/// catch is left to the model behind it.
public struct WordFilter: Sendable {
    /// Characters that read as letters (`LexicalTextFilter.LEET`).
    static let leet: [Unicode.Scalar: Unicode.Scalar] = [
        "0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "8": "b", "@": "a", "$": "s", "!": "i", "|": "i",
    ]
    /// The shortest run of one letter that collapses to one.
    private static let stretched = 3

    private let blocked: Set<String>
    private let blockedCollapsed: Set<String>
    private let allowed: Set<String>

    /// A filter that flags `words` and never `allowed`, each folded as a message is.
    public init(words: some Sequence<String>, allowed: [String] = []) {
        let folded = Set(words.map(Self.fold).filter { !$0.isEmpty })
        blocked = folded
        blockedCollapsed = Set(folded.map(Self.collapsed))
        self.allowed = Set(allowed.map(Self.fold).filter { !$0.isEmpty })
    }

    /// The list in `text`, one word a line, where a line that is blank or starts with `#` says nothing
    /// (`WordList.loadProfanity`).
    public init(list text: String) {
        self.init(words: Self.terms(in: text))
    }

    /// The terms of a bundled list, one a line: each line trimmed as Kotlin's `trim` trims it, and a line that is blank
    /// or starts with `#` left out (`WordList.load`). The name screen reads its lists the same way.
    public static func terms(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { TextLimits.trimmed(String($0)) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Whether `text` holds a listed word.
    public func flags(_ text: String) -> Bool {
        guard !blocked.isEmpty, !TextLimits.isBlank(text) else {
            return false
        }
        // Runs of single letters build up, so a spaced-out word is tested whole.
        var singles = ""
        let letters = Self.fold(text).unicodeScalars.split { !("a"..."z").contains($0) }
        for word in letters.map({ String(String.UnicodeScalarView($0)) }) {
            if isBlocked(word) {
                return true
            }
            if word.unicodeScalars.count == 1 {
                singles += word
            } else if !singles.isEmpty {
                if isBlocked(singles) {
                    return true
                }
                singles = ""
            }
        }
        return isBlocked(singles)
    }

    /// Whether `word` is a listed word as written, or, only when it was itself stretched, a listed word's collapsed
    /// form (knit-next `df7d33012`). A word with nothing to collapse is not stretched: asking it anyway made a lone `x`
    /// match `xxx`, whose collapsed form is `x`, so "2 x 3" was blocked in the room.
    private func isBlocked(_ word: String) -> Bool {
        guard !word.isEmpty, !allowed.contains(word) else {
            return false
        }
        if blocked.contains(word) {
            return true
        }
        let collapsed = Self.collapsed(word)
        return collapsed != word && blockedCollapsed.contains(collapsed)
    }

    /// `raw` lowercased, NFKD with its nonspacing marks dropped, and its leetspeak read as letters
    /// (`LexicalTextFilter.normalize`, which ``NameScreen`` shares).
    static func fold(_ raw: String) -> String {
        let folded = raw.lowercased().decomposedStringWithCompatibilityMapping.unicodeScalars
            .filter { $0.properties.generalCategory != .nonspacingMark }
            .map { leet[$0] ?? $0 }
        return String(String.UnicodeScalarView(folded))
    }

    /// `word` with each run of ``stretched`` or more of one letter made one, and a pair left alone
    /// (`LexicalTextFilter.collapseRuns`, which ``NameScreen`` shares).
    static func collapsed(_ word: String) -> String {
        var out = String.UnicodeScalarView()
        var run: (letter: Unicode.Scalar, count: Int)?
        func close() {
            if let run {
                out.append(contentsOf: repeatElement(run.letter, count: run.count >= stretched ? 1 : run.count))
            }
        }
        for letter in word.unicodeScalars {
            if run?.letter == letter {
                run?.count += 1
            } else {
                close()
                run = (letter, 1)
            }
        }
        close()
        return String(out)
    }
}
