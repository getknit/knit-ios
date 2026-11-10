/// Java's `Character` predicates on one UTF-16 unit, as `charAt` hands them over: a surrogate is its own category,
/// neither a space, a control nor a format character.
internal enum JavaChar {
    /// `Character.isISOControl`: U+0000–U+001F and U+007F–U+009F.
    static func isISOControl(_ unit: UInt16) -> Bool {
        unit <= lastC0 || (deleteControl...lastC1).contains(unit)
    }

    /// `Character.isSpaceChar`: the space, line and paragraph separators (Zs, Zl, Zp).
    static func isSpaceChar(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else {
            return false
        }
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return false
        }
    }

    /// `Char.category == CharCategory.FORMAT` (Cf), which holds the bidi marks, embeddings, overrides and isolates.
    static func isFormat(_ unit: UInt16) -> Bool {
        Unicode.Scalar(unit)?.properties.generalCategory == .format
    }

    /// Kotlin's `Char.isWhitespace` on ART (``TextLimits/isKotlinWhitespace(_:)``); a surrogate never is.
    static func isWhitespace(_ unit: UInt16) -> Bool {
        Unicode.Scalar(unit).map(TextLimits.isKotlinWhitespace) ?? false
    }

    private static let lastC0: UInt16 = 0x1F
    private static let deleteControl: UInt16 = 0x7F
    private static let lastC1: UInt16 = 0x9F
}
