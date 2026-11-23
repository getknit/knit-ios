import KnitWire

extension NameKey {
    /// ``NameKey/of(_:)``'s answer, without its Unicode passes when `text` allows: printable ASCII, single spaces inside
    /// it and none at either end, which every alias label is (`"ReallyJoyfulFerret (QuietlyBoldCedar)"`). For such a text
    /// NFKC changes nothing, the lookalike table holds only `I` (to `l`), nothing is a mark or a format character, and
    /// there is no whitespace run or edge to collapse or trim. So the key is the text lowercased with `i` for `l`.
    /// Anything else takes ``NameKey/of(_:)`` itself. `NameKeyQuickTests` holds the two equal.
    ///
    /// The received-mention rule keys up to eleven label texts for each node id a list names (knit-ios #36), and on Linux
    /// ``NameKey/of(_:)`` costs about a microsecond a character.
    static func quick(_ text: String) -> String {
        var key = String.UnicodeScalarView()
        var previous: UInt8 = space
        for byte in text.utf8 {
            guard (space...tilde).contains(byte), byte != space || previous != space else {
                return of(text)
            }
            let lower = (capitalA...capitalZ).contains(byte) ? byte + caseOffset : byte
            key.append(Unicode.Scalar(lower == smallL ? smallI : lower))
            previous = byte
        }
        guard previous != space else {
            // Empty, or ending in a space, which `of` trims.
            return of(text)
        }
        return String(key)
    }

    private static let space = UInt8(ascii: " ")
    private static let tilde = UInt8(ascii: "~")
    private static let capitalA = UInt8(ascii: "A")
    private static let capitalZ = UInt8(ascii: "Z")
    private static let caseOffset = UInt8(ascii: "a") - UInt8(ascii: "A")
    private static let smallL = UInt8(ascii: "l")
    private static let smallI = UInt8(ascii: "i")
}
