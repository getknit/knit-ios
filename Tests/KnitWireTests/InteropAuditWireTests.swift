import KnitWire
import Testing

/// Repros for the interop audit of 2026-10-09 (`interop-audit`, knit-next 8dc60836 against knit-ios 0b19f2d). Each one
/// asserts what Android does. A divergence still standing sits inside `withKnownIssue`, so the suite passes while it
/// stands and fails once a fix lands: then drop the `withKnownIssue` and keep the test.
@Suite struct InteropAuditWireTests {
    /// IOS-2 (AND-13): on ART, `java.util.regex` is ICU (`com.android.icu.util.regex.PatternNative`), and `\s` is
    /// `\p{IsWhite_Space}` (android-36.1 `Pattern.java:178-179`), so `normalizeSingleLine`'s `Regex("\\s+")`
    /// (`TextLimits.kt:47-49`) collapses a no-break space, U+0085, U+1680, U+2000-U+200A, U+2028, U+2029, U+202F, U+205F
    /// and U+3000. This port collapsed ASCII alone until ADR 2026-10.7uyt.
    @Test(arguments: ["\u{00A0}\u{00A0}", "\u{0085}", "\u{1680}", "\u{2003}", "\u{2028}", "\u{2029}", "\u{202F}", "\u{3000}"])
    func unicodeWhiteSpaceInsideANameCollapsesAsOnAndroid(space: String) {
        #expect(TextLimits.normalizeSingleLine("Ann\(space)Lee") == "Ann Lee")
    }

    /// IOS-2: the audit read ART's `Character.isWhitespace` hard-coding U+180E (android-36.1 `Character.java:11812-11815`).
    /// knit-next's `ArtTextSemanticsTest` found that answer follows the ART mainline module: whitespace up to API 36's,
    /// not from API 37's, as in Unicode 6.3. The law takes the current answer (ADR 2026-10.7uyt), so a rename to U+180E
    /// alone is a name, and an older module's `isNotBlank()` (`InboundPipeline.kt:2109`) ignoring it is accepted.
    @Test func mongolianVowelSeparatorIsNotWhitespaceAsOnCurrentART() {
        #expect(!TextLimits.isBlank("\u{180E}"))
        #expect(TextLimits.outgoingGroupName("\u{180E}") == "\u{180E}")
        #expect(TextLimits.incomingGroupName("\u{180E}") == "\u{180E}")
        #expect(TextLimits.normalizeSingleLine("\u{180E}Ann\u{180E}") == "\u{180E}Ann\u{180E}")
    }

    /// IOS-5: a signed frame whose text is not UTF-8 is refused here (RFC 8949), while kotlinx-serialization-cbor 1.11.0
    /// reads it with `decodeToString()` (`Decoder.kt:285`), which puts U+FFFD in place of the bad bytes. Android then
    /// verifies it over the raw `signed` bytes, carries it and lists the lossy id in its digest, which never agrees with
    /// this port's. This pins the half this port owns: the item is refused, not repaired.
    @Test func textThatIsNotUTF8IsRefusedWhereKotlinxRepairsIt() {
        // {"id": "a\u{FF}"}: a one-entry map whose value is a two-byte text string holding an invalid byte.
        let item: [UInt8] = [0xA1, 0x62, 0x69, 0x64, 0x62, 0x61, 0xFF]
        #expect(throws: CBORError.invalidUTF8) {
            _ = try CBOR.decode(item)
        }
    }
}
