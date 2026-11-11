/// How ART's `Charset.forName` finds the charsets this module decodes. ART asks ICU before it checks the name
/// (`Charset.lookup2`, android-37.2, then `NativeConverter.charsetForName`), and ICU compares names loosely
/// (`ucnv_compareNames`), so `utf8`, `UTF_8`, `latin-1` and `ISO8859-1` all name a charset, where the desktop JDK knows
/// only its listed aliases.
extension PageCharset {
    /// The charset among this module's that ART finds for `name`, or `nil` for any other name: one ICU leaves to another
    /// converter, or none. A name ICU doesn't know is tried again without an `x-` before it, as ART's bridge does.
    init?(artName name: String) {
        let unprefixed = name.hasPrefix(Self.extensionPrefix) ? String(name.dropFirst(Self.extensionPrefix.count)) : nil
        guard let charset = Self.icuCharset(name) ?? unprefixed.flatMap(Self.icuCharset) else {
            return nil
        }
        self = charset
    }

    /// The charset `name` is an ICU alias of, compared loosely, or `nil`. ICU refuses a name of 60 bytes or more in the
    /// modified UTF-8 that JNI hands it (`UCNV_MAX_CONVERTER_NAME_LENGTH`): a unit below U+0080 is one byte, below
    /// U+0800 two, and any other three, each half of a surrogate pair included.
    private static func icuCharset(_ name: String) -> Self? {
        let jniLength = name.utf16.reduce(0) { length, unit in
            length + (unit < oneByteEnd ? 1 : unit < twoByteEnd ? twoBytes : threeBytes)
        }
        return jniLength < maxNameLength ? aliases[looseKey(name)] : nil
    }

    /// `ucnv_io_stripASCIIForCompare`: letters lower-cased, digits kept but for a `0` that leads a run of digits, and
    /// everything else dropped, bytes past ASCII included.
    private static func looseKey(_ name: String) -> String {
        let bytes = Array(name.utf8)
        var key = ""
        var afterDigit = false
        for (index, byte) in bytes.enumerated() {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"):
                key.append(Character(Unicode.Scalar(byte | caseBit)))
                afterDigit = false
            case UInt8(ascii: "0"):
                // A `0` keeps `afterDigit` as it was, and goes when it leads another digit.
                if !afterDigit, index + 1 < bytes.count, digits.contains(bytes[index + 1]) {
                    continue
                }
                key.append("0")
            case UInt8(ascii: "1")...UInt8(ascii: "9"):
                key.append(Character(Unicode.Scalar(byte)))
                afterDigit = true
            default:
                afterDigit = false
            }
        }
        return key
    }

    /// ICU's aliases of each charset this module decodes, by their loose keys; `ibm-819` and `IBM819` share one.
    private static let aliases = Dictionary(aliasNames.flatMap { charset, names in names.map { (looseKey($0), charset) } }) { first, _ in
        first
    }

    /// ICU 74's aliases (`convrtrs.txt`, as `uconv --canon -l` lists them) of each charset this module decodes. `UTF-16`
    /// without a mark reads big-endian, as ICU's converter reads it.
    private static let aliasNames: [(Self, [String])] = [
        (
            .utf8,
            [
                "UTF-8", "ibm-1208", "ibm-1209", "ibm-5304", "ibm-5305", "ibm-13496", "ibm-13497", "ibm-17592", "ibm-17593",
                "windows-65001", "cp1208", "x-UTF_8J", "unicode-1-1-utf-8", "unicode-2-0-utf-8",
            ]
        ),
        (
            .utf16BigEndian,
            [
                "UTF-16", "ISO-10646-UCS-2", "ibm-1204", "ibm-1205", "unicode", "csUnicode", "ucs-2", "UTF-16BE", "x-utf-16be",
                "UnicodeBigUnmarked", "ibm-1200", "ibm-1201", "ibm-13488", "ibm-13489", "ibm-17584", "ibm-17585", "ibm-21680",
                "ibm-21681", "ibm-25776", "ibm-25777", "ibm-29872", "ibm-29873", "ibm-61955", "ibm-61956", "windows-1201",
                "cp1200", "cp1201", "UTF16_BigEndian",
            ]
        ),
        (
            .utf16LittleEndian,
            [
                "UTF-16LE", "x-utf-16le", "UnicodeLittleUnmarked", "ibm-1202", "ibm-1203", "ibm-13490", "ibm-13491",
                "ibm-17586", "ibm-17587", "ibm-21682", "ibm-21683", "ibm-25778", "ibm-25779", "ibm-29874", "ibm-29875",
                "UTF16_LittleEndian", "windows-1200",
            ]
        ),
        (
            .isoLatin1,
            [
                "ISO-8859-1", "ibm-819", "IBM819", "cp819", "latin1", "8859_1", "csISOLatin1", "iso-ir-100", "ISO_8859-1:1987",
                "l1", "819",
            ]
        ),
        (.windows1252, ["ibm-5348_P100-1997", "ibm-5348", "windows-1252", "cp1252"]),
        (
            .usASCII,
            [
                "US-ASCII", "ASCII", "ANSI_X3.4-1968", "ANSI_X3.4-1986", "ISO_646.irv:1991", "iso_646.irv:1983", "ISO646-US",
                "us", "csASCII", "iso-ir-6", "cp367", "ascii7", "646", "windows-20127", "ibm-367", "IBM367",
            ]
        ),
    ]

    /// The prefix ART's bridge takes off a name ICU doesn't know (`getICUCanonicalName`).
    private static let extensionPrefix = "x-"
    private static let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
    private static let caseBit: UInt8 = 0x20
    private static let oneByteEnd: UInt16 = 0x80
    private static let twoByteEnd: UInt16 = 0x800
    private static let twoBytes = 2
    private static let threeBytes = 3
    private static let maxNameLength = 60
}
