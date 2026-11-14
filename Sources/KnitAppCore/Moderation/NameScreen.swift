import KnitWire

/// Screens a name against the word lists (`NameScreen.kt`, knit-next ADR 2026-11.y4pc): a display name, a status line
/// or a group's name. No model reads a name, and the message filter's whole-word rule alone misses most of the shapes a
/// username takes (`BigD1ck69`, `xXslurXx`), so a name is read three ways:
///
/// - **as split variants:** as written, with camelCase boundaries split, and with digit runs as separators, each run
///   through the whole-word ``WordFilter``. Trying the name as written as well keeps leetspeak working.
/// - **inside its words,** for the embeddable terms alone: those no dictionary word or real name holds, so "pikey" is
///   found in "pikeyboy" while "dick" is never looked for in "Dickson". A word is cut at each exclusion first
///   ("spikey" holds "pikey"), and a digit is a leet letter there only between two letters, so `ashish17tripathi`
///   holds nothing.
/// - **with real names allowed:** a profanity term that is also a given name or a surname (Dick, Coon, Shota) passes as
///   a word in plain letters, so "Dick Smith" passes and `BigD1ck69` does not. A slur never does.
///
/// It reads text as Android's `java.util.regex` does on ART, which runs ICU: the classes are per code point, from the
/// general category, `\s` is Unicode White_Space, and the digit rule walks UTF-16 units, as Kotlin's `Char` does. Swift's
/// Unicode tables can be a version apart from ART's, so only a code point new to one of them would read differently.
/// knit-next's `vectors/name-screen-v1.json` holds the two apps to one verdict.
public struct NameScreen: Sendable {
    /// Who sees a name (`NameScreen.Audience`).
    public enum Audience: Sendable, Hashable {
        /// Everyone in range, strangers included: a person's name and status (`PUBLIC`). Both lists, the room's rules.
        case everyone
        /// A group's members alone: its name (`MEMBERS`). The slur list alone, the private scope of knit-next ADR
        /// 2026-10.d62w.
        case members
    }

    /// What a name holds (`TextVerdict.Category`).
    public enum Verdict: Sendable, Equatable {
        /// Nothing listed.
        case allowed
        /// A term of the slur list.
        case slur
        /// A term of the profanity list.
        case profanity

        /// Whether the name holds a listed term.
        public var flagged: Bool { self != .allowed }
    }

    /// The shortest term looked for inside a word (`MIN_INSIDE`).
    private static let shortestInside = 4
    /// The four symbols the filter reads as letters, which stay inside the token they are part of.
    private static let leetSymbols: Set<Unicode.Scalar> = ["@", "$", "!", "|"]

    private let slurs: WordFilter
    private let profanity: WordFilter
    private let allowed: Set<String>
    private let insideSlurs: [[UInt8]]
    private let insideProfanity: [[UInt8]]
    private let cuts: [[UInt8]]

    /// The screen over the five lists: `slurs` and `profanity`, the terms of them `embeddable` inside a word, the benign
    /// `exclusions` that hold one, and the `allowedNames`, profanity terms that are real names. Every term is folded as a
    /// message is.
    public init(slurs: [String], profanity: [String], embeddable: [String], exclusions: [String], allowedNames: [String]) {
        let slurTerms = Self.folded(slurs)
        let profanityTerms = Self.folded(profanity)
        self.slurs = WordFilter(words: slurTerms)
        self.profanity = WordFilter(words: profanityTerms)
        allowed = Self.folded(allowedNames).subtracting(slurTerms)
        let inside = Self.folded(embeddable).filter { $0.utf16.count >= Self.shortestInside }
        insideSlurs = inside.intersection(slurTerms).sorted().map { Array($0.utf8) }
        insideProfanity = inside.intersection(profanityTerms).subtracting(slurTerms).sorted().map { Array($0.utf8) }
        cuts = exclusions.map(WordFilter.fold).filter { !$0.isEmpty }.map { Array($0.utf8) }
    }

    /// What `name` holds, read for `audience`. A blank name holds nothing.
    public func check(_ name: String, audience: Audience) -> Verdict {
        guard !TextLimits.isBlank(name) else {
            return .allowed
        }
        if Self.variants(name).contains(where: slurs.flags) || holds(name, insideSlurs) {
            return .slur
        }
        guard audience == .everyone else {
            return .allowed
        }
        let rest = withoutRealNames(name)
        if Self.variants(rest).contains(where: profanity.flags) || holds(rest, insideProfanity) {
            return .profanity
        }
        return .allowed
    }

    // MARK: Variants

    /// The name as written, camel-split, with its digit runs as spaces, and both, each once.
    private static func variants(_ name: String) -> [String] {
        let spaced = digitRunsSpaced(name)
        var variants: [String] = []
        for variant in [name, splitCamel(name), spaced, splitCamel(spaced)] where !variants.contains(variant) {
            variants.append(variant)
        }
        return variants
    }

    /// `text` with each run of `\p{Nd}` made one space (`DIGIT_RUN`).
    private static func digitRunsSpaced(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var inRun = false
        for scalar in text.unicodeScalars {
            if scalar.properties.generalCategory == .decimalNumber {
                if !inRun {
                    out.append(" ")
                }
                inRun = true
            } else {
                out.append(scalar)
                inRun = false
            }
        }
        return String(out)
    }

    /// `text` with a space where a lower-case letter meets a capital (`LOWER_THEN_UPPER`), then where a capital starts a
    /// capitalised word after another capital (`UPPER_THEN_WORD`): `BigShit` is `Big Shit`, `XMLParser` is `XML Parser`.
    private static func splitCamel(_ text: String) -> String {
        let lowerThenUpper = spaced(Array(text.unicodeScalars)) { scalars, index in
            category(scalars[index - 1]) == .lowercaseLetter && category(scalars[index]) == .uppercaseLetter
        }
        let upperThenWord = spaced(lowerThenUpper) { scalars, index in
            index + 1 < scalars.count && category(scalars[index - 1]) == .uppercaseLetter
                && category(scalars[index]) == .uppercaseLetter && category(scalars[index + 1]) == .lowercaseLetter
        }
        return String(String.UnicodeScalarView(upperThenWord))
    }

    /// `scalars` with a space before each index past the first where `boundary` holds, as Kotlin's `replace` fills a
    /// zero-width match: each boundary is read on the text as it was.
    private static func spaced(
        _ scalars: [Unicode.Scalar], where boundary: ([Unicode.Scalar], Int) -> Bool
    ) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(scalars.count)
        for index in scalars.indices {
            if index > 0, boundary(scalars, index) {
                out.append(" ")
            }
            out.append(scalars[index])
        }
        return out
    }

    /// `name` camel-split, with every run of letters that folds to an allowed real name made a space ("Dick Smith" is
    /// " Smith"). A run holds letters alone, so a leet spelling is never a name. With no names allowed, `name` as it is.
    private func withoutRealNames(_ name: String) -> String {
        guard !allowed.isEmpty else {
            return name
        }
        var out = String.UnicodeScalarView()
        var run = String.UnicodeScalarView()
        func close() {
            if !run.isEmpty {
                if allowed.contains(WordFilter.fold(String(run))) {
                    out.append(" ")
                } else {
                    out.append(contentsOf: run)
                }
                run = String.UnicodeScalarView()
            }
        }
        for scalar in Self.splitCamel(name).unicodeScalars {
            if Self.isLetter(scalar) {
                run.append(scalar)
            } else {
                close()
                out.append(scalar)
            }
        }
        close()
        return String(out)
    }

    // MARK: Inside words

    /// Whether a word of `name`, read inside, holds one of `terms`: each token's digits read between letters, the token
    /// folded and split at whatever is not a-z, each word cut at the exclusions, and each piece tested as it is and with
    /// its stretched letters collapsed.
    private func holds(_ name: String, _ terms: [[UInt8]]) -> Bool {
        guard !terms.isEmpty else {
            return false
        }
        for token in Self.tokens(of: name) {
            let letters = WordFilter.fold(Self.flankedLeet(token)).unicodeScalars.split { !("a"..."z").contains($0) }
            for word in letters {
                for piece in cut(word.map { UInt8($0.value) }) {
                    let collapsed = Self.collapsed(piece)
                    if terms.contains(where: { Self.find($0, in: piece) || Self.find($0, in: collapsed) }) {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// `name`'s tokens: what lies between runs of whitespace, punctuation and symbols, except the leet symbols
    /// (`TOKEN_SEPARATORS`, `[\s\p{P}\p{S}&&[^@$!|]]+`).
    private static func tokens(of name: String) -> [String] {
        name.unicodeScalars.split(whereSeparator: isSeparator).map { String(String.UnicodeScalarView($0)) }
    }

    private static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        guard !leetSymbols.contains(scalar) else {
            return false
        }
        if TextLimits.isJavaRegexWhitespace(scalar) {
            return true
        }
        switch category(scalar) {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
            .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }

    /// `token` with each digit read as its leet letter where a letter stands on both sides (`sh1t`), and as a space
    /// anywhere else (`flankedLeet`). Kotlin reads `Char`s, UTF-16 units, so half a surrogate pair is never a letter.
    private static func flankedLeet(_ token: String) -> String {
        let units = Array(token.utf16)
        var out: [UInt16] = []
        out.reserveCapacity(units.count)
        let space = UInt16(UInt8(ascii: " "))
        for (index, unit) in units.enumerated() {
            guard unitCategory(unit) == .decimalNumber else {
                out.append(unit)
                continue
            }
            let between = index > 0 && index < units.count - 1 && isLetter(units[index - 1]) && isLetter(units[index + 1])
            let letter = Unicode.Scalar(unit).flatMap { WordFilter.leet[$0] }.map { UInt16($0.value) }
            out.append(between ? letter ?? space : space)
        }
        return String(decoding: out, as: UTF16.self)
    }

    /// `piece` with its stretched letters collapsed, as ``WordFilter`` collapses them.
    private static func collapsed(_ piece: [UInt8]) -> [UInt8] {
        Array(WordFilter.collapsed(String(String.UnicodeScalarView(piece.map(Unicode.Scalar.init)))).utf8)
    }

    /// `word` split at every exclusion it holds, in the list's order, so "spikeyboy" is read as "boy".
    private func cut(_ word: [UInt8]) -> [[UInt8]] {
        var pieces = [word]
        for exclusion in cuts {
            pieces = pieces.flatMap { Self.split($0, at: exclusion) }
        }
        return pieces.filter { !$0.isEmpty }
    }

    /// `bytes` split at each occurrence of `separator`, left to right, empty pieces kept, as Kotlin's `split` does.
    private static func split(_ bytes: [UInt8], at separator: [UInt8]) -> [[UInt8]] {
        var pieces: [[UInt8]] = []
        var start = 0
        var index = 0
        while index + separator.count <= bytes.count {
            if bytes[index..<(index + separator.count)].elementsEqual(separator) {
                pieces.append(Array(bytes[start..<index]))
                index += separator.count
                start = index
            } else {
                index += 1
            }
        }
        pieces.append(Array(bytes[start...]))
        return pieces
    }

    /// Whether `needle` occurs in `haystack`, byte by byte: both are a-z, where a `String` search would compare
    /// characters.
    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Bool {
        guard needle.count <= haystack.count else {
            return false
        }
        for start in 0...(haystack.count - needle.count) where haystack[start..<(start + needle.count)].elementsEqual(needle) {
            return true
        }
        return false
    }

    // MARK: Characters

    private static func folded(_ terms: [String]) -> Set<String> {
        Set(terms.map(WordFilter.fold).filter { !$0.isEmpty })
    }

    private static func category(_ scalar: Unicode.Scalar) -> Unicode.GeneralCategory {
        scalar.properties.generalCategory
    }

    /// A UTF-16 unit's category, as Kotlin's `Char` reads it; a surrogate half has none of the categories asked about.
    private static func unitCategory(_ unit: UInt16) -> Unicode.GeneralCategory? {
        Unicode.Scalar(unit).map(category)
    }

    /// `\p{L}` and Kotlin's `isLetter`: Lu, Ll, Lt, Lm or Lo.
    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch category(scalar) {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            true
        default:
            false
        }
    }

    private static func isLetter(_ unit: UInt16) -> Bool {
        Unicode.Scalar(unit).map(isLetter) ?? false
    }
}
