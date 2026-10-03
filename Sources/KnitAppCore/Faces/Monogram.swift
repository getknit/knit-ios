/// The letter a face without a photo shows (`avatarInitial` in knit-next's `ui/components/Avatar.kt`).
public enum Monogram {
    /// What a blank name shows.
    public static let blank = "?"

    /// The first character of `name` a person would see, once leading whitespace is gone, upper-cased, or ``blank`` for
    /// a blank name. A Swift `Character` is an extended grapheme cluster, as Android's `BreakIterator` steps by, so a
    /// leading emoji, a flag or a family keeps its whole cluster rather than a lone surrogate that draws as a missing
    /// glyph.
    public static func initial(of name: String) -> String {
        let trimmed = String(String.UnicodeScalarView(name.unicodeScalars.drop(while: \.properties.isWhitespace)))
        return trimmed.first.map { String($0).uppercased() } ?? blank
    }
}
