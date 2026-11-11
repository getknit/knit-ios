import Testing

@testable import KnitAppCore

/// A page's bytes as text, and the character references in it.
extension OpenGraphParserTests {
    /// `text`'s code points as ISO-8859-1 bytes; every one is below U+0100.
    private func latin1(_ text: String) -> [UInt8] {
        text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
    }

    // MARK: - OpenGraphParserTest.kt

    @Test func charsetComesFromTheBomThenTheHeaderThenTheMetaThenUtf8() throws {
        let utf8 = Array("<meta charset=\"utf-8\"><title>Gr\u{FC}\u{DF}e</title>".utf8)
        #expect(OpenGraphParser.charsetOf(utf8, contentType: nil) == .utf8)
        let latin1 = latin1("<title>Gr\u{FC}\u{DF}e</title>")
        #expect(OpenGraphParser.charsetOf(latin1, contentType: "text/html; charset=ISO-8859-1") == .isoLatin1)
        let decoded = OpenGraphParser.decode(latin1, contentType: "text/html; charset=iso-8859-1")
        #expect(try #require(OpenGraphParser.parse(decoded, finalURL: "https://example.com/")).title == "Gr\u{FC}\u{DF}e")
        let metaLatin = Array("<meta http-equiv=\"Content-Type\" content=\"text/html; charset=windows-1252\"><title>x</title>".utf8)
        #expect(OpenGraphParser.charsetOf(metaLatin, contentType: "text/html") == .windows1252)
        let bom = [0xEF, 0xBB, 0xBF] + Array("<title>Bom</title>".utf8)
        #expect(OpenGraphParser.charsetOf(bom, contentType: "text/html; charset=ISO-8859-1") == .utf8)
        #expect(
            try #require(OpenGraphParser.parse(OpenGraphParser.decode(bom, contentType: nil), finalURL: "https://example.com/")).title
                == "Bom")
        let unknown = Array("<title>x</title>".utf8)
        #expect(OpenGraphParser.charsetOf(unknown, contentType: "text/html; charset=no-such-charset") == .utf8)
    }

    @Test func malformedBytesDecodeWithReplacementRatherThanThrowing() throws {
        let broken = Array("<title>ok</title>".utf8) + [0xFF, 0xFE, 0x41]
        #expect(OpenGraphParser.decode(broken, contentType: "text/html; charset=utf-8") == "<title>ok</title>\u{FFFD}\u{FFFD}A")
        let page = OpenGraphParser.decode(broken, contentType: "text/html; charset=utf-8")
        #expect(try #require(OpenGraphParser.parse(page, finalURL: "https://example.com/")).title == "ok")
    }

    // MARK: - Names, as ART finds them

    /// ART asks ICU before it checks a name, and ICU compares names loosely: case, punctuation, a leading zero and any
    /// byte past ASCII aside, and an `x-` taken off when nothing else matches.
    @Test(arguments: [
        ("utf8", PageCharset.utf8), ("UTF_8", .utf8), ("unicode-1-1-utf-8", .utf8), ("latin-1", .isoLatin1),
        ("ISO8859-1", .isoLatin1), ("iso-8859-01", .isoLatin1), ("x-latin1", .isoLatin1), ("latin1\u{E9}", .isoLatin1),
        ("cp1252", .windows1252), ("Windows-1252", .windows1252), ("us-ascii", .usASCII), ("646", .usASCII),
        ("utf-16", .utf16BigEndian), ("UnicodeBigUnmarked", .utf16BigEndian), ("utf-16le", .utf16LittleEndian),
    ])
    func aNameIsMatchedLooselyAsICUMatchesIt(name: String, charset: PageCharset) {
        #expect(OpenGraphParser.charsetOf(Array("<meta charset=\(name)>".utf8), contentType: nil) == charset)
    }

    /// ICU refuses a name of 60 bytes or more, counted in JNI's modified UTF-8; a refused name falls through.
    @Test func aNameOfSixtyBytesOrMoreIsNoName() {
        let page = Array("<meta charset=windows-1252>".utf8)
        let fiftyNine = "latin1" + String(repeating: ".", count: 53)
        #expect(OpenGraphParser.charsetOf(page, contentType: "text/html; charset=\(fiftyNine)") == .isoLatin1)
        #expect(OpenGraphParser.charsetOf(page, contentType: "text/html; charset=\(fiftyNine).") == .windows1252)
        // 6 bytes, then 26 of 2, one of 3, and a pair of 3 each: 67, though only 34 UTF-16 units.
        let wide = "latin1" + String(repeating: "\u{E9}", count: 26) + "\u{4E00}" + "\u{1D400}"
        #expect(OpenGraphParser.charsetOf(page, contentType: "text/html; charset=\(wide)") == .windows1252)
        let narrow = "latin1" + String(repeating: "\u{E9}", count: 22) + "\u{4E00}"
        #expect(OpenGraphParser.charsetOf(page, contentType: "text/html; charset=\(narrow)") == .isoLatin1)
    }

    /// The parameter's `charset` folds case as ICU does, and `\s` is ART's; the first that names something wins.
    @Test func theContentTypesParameterIsReadAsTheRegexReadsIt() {
        let page = Array("<title>x</title>".utf8)
        #expect(OpenGraphParser.charsetOf(page, contentType: "text/html; CHAR\u{17F}ET\u{2028}=\u{A0}'cp1252'") == .windows1252)
        #expect(OpenGraphParser.charsetOf(page, contentType: "text/html; charset=\" latin1\"") == .utf8)
        #expect(OpenGraphParser.charsetOf(page, contentType: "text/html; charset ; charset=latin1") == .isoLatin1)
        #expect(OpenGraphParser.charsetOf(page, contentType: "text/html; charset=\u{1F600}") == .utf8)
    }

    /// Within a `<meta>`, the last `charset` before its `>` wins, as the greedy `[^>]*` gives back from the right; the
    /// first `<meta>` that holds one decides, whether or not its name is known; the tag needn't close in the sniffed head.
    @Test func theMetaCharsetIsTheLastInTheFirstTagThatHasOne() {
        #expect(
            OpenGraphParser.charsetOf(Array(#"<meta charset="windows-1252" data-charset="latin1">"#.utf8), contentType: nil) == .isoLatin1)
        #expect(OpenGraphParser.charsetOf(Array(#"<meta name="x"><META CHARSET = 'cp1252'>"#.utf8), contentType: nil) == .windows1252)
        #expect(OpenGraphParser.charsetOf(Array(#"<meta charset="nope"><meta charset="latin1">"#.utf8), contentType: nil) == .utf8)
        #expect(OpenGraphParser.charsetOf(Array("<metacharset=latin1><meta charset=latin1".utf8), contentType: nil) == .isoLatin1)
        let late = Array((String(repeating: " ", count: OpenGraphParser.charsetSniffBytes) + "<meta charset=latin1>").utf8)
        #expect(OpenGraphParser.charsetOf(late, contentType: nil) == .utf8)
    }

    // MARK: - The platform's decoder

    /// A name this module leaves to the platform reaches its decoder with the bytes; a name the decoder doesn't know
    /// falls through to the next source, and with no decoder at all, to UTF-8.
    @Test func otherCharsetsGoToTheInjectedDecoder() {
        let decoder: OpenGraphParser.CharsetDecoder = { name, bytes in
            name.lowercased() == "shift_jis" ? "\(name):\(bytes.count)" : nil
        }
        let page = Array("<meta charset=Shift_JIS><title>x</title>".utf8)
        #expect(OpenGraphParser.charsetOf(page, contentType: nil, decoder: decoder) == .named("Shift_JIS"))
        #expect(OpenGraphParser.decode(page, contentType: nil, decoder: decoder) == "Shift_JIS:\(page.count)")
        #expect(OpenGraphParser.charsetOf(page, contentType: "text/html; charset=koi8-r", decoder: decoder) == .named("Shift_JIS"))
        #expect(OpenGraphParser.charsetOf(page, contentType: nil) == .utf8)
        #expect(
            OpenGraphParser.decode(page, contentType: "text/html; charset=latin1", decoder: decoder)
                == "<meta charset=Shift_JIS><title>x</title>")
    }

    // MARK: - This module's decoders

    @Test func theBuiltInCharsetsDecodeAsARTDoes() {
        #expect(OpenGraphParser.decode([0x41, 0x80, 0xE9], contentType: "text/html; charset=latin1") == "A\u{80}\u{E9}")
        let windows = OpenGraphParser.decode([0x80, 0x81, 0x8D, 0x9F, 0xE9], contentType: "text/html; charset=windows-1252")
        #expect(windows == "\u{20AC}\u{81}\u{8D}\u{178}\u{E9}")
        #expect(OpenGraphParser.decode([0x41, 0xE9], contentType: "text/html; charset=us-ascii") == "A\u{FFFD}")
        // UTF-8: one U+FFFD for each maximal subpart, as ICU and ART replace them.
        let utf8 = OpenGraphParser.decode([0xC3, 0x28, 0xE2, 0x82, 0xFF, 0xF0, 0x9F, 0x98], contentType: nil)
        #expect(utf8 == "\u{FFFD}(\u{FFFD}\u{FFFD}\u{FFFD}")
    }

    /// UTF-16 by its mark, which is dropped, or by name with none, big-endian. An unpaired surrogate is replaced, and a
    /// last odd byte too, in the same U+FFFD as an unpaired lead before it, as ICU reports them.
    @Test func utf16IsReadByItsMarkOrItsName() {
        #expect(OpenGraphParser.charsetOf([0xFE, 0xFF, 0x00, 0x41], contentType: nil) == .utf16BigEndian)
        #expect(OpenGraphParser.decode([0xFE, 0xFF, 0x00, 0x41, 0xD8, 0x3D, 0xDE, 0x00], contentType: nil) == "A\u{1F600}")
        #expect(OpenGraphParser.decode([0xFF, 0xFE, 0x41, 0x00, 0x3D, 0xD8, 0x00, 0xDE], contentType: nil) == "A\u{1F600}")
        #expect(OpenGraphParser.decode([0xFF, 0xFE, 0x41, 0x00, 0x42], contentType: nil) == "A\u{FFFD}")
        #expect(OpenGraphParser.decode([0xFE, 0xFF, 0xD8, 0x00, 0x41], contentType: nil) == "\u{FFFD}")
        #expect(OpenGraphParser.decode([0xFE, 0xFF, 0xD8, 0x00, 0x00, 0x41], contentType: nil) == "\u{FFFD}A")
        #expect(OpenGraphParser.decode([0x00, 0x41, 0x00, 0x42], contentType: "text/html; charset=utf-16") == "AB")
    }

    // MARK: - Character references

    @Test func characterReferencesDecodeInOnePassAndAnythingElseStaysAsWritten() {
        #expect(OpenGraphParser.decodeEntities("plain") == "plain")
        #expect(OpenGraphParser.decodeEntities("&#X41;&#x61;&#65;&#0066;&#x0000043;") == "AaABC")
        #expect(OpenGraphParser.decodeEntities("&amp;lt; &&amp; a & b") == "&lt; && a & b")
        #expect(
            OpenGraphParser.decodeEntities("&#abc; &#x; &#xyz; &#; &AMP; &1a; &a1; &#x110000; &#99999999999;")
                == "&#abc; &#x; &#xyz; &#; &AMP; &1a; &a1; &#x110000; &#99999999999;")
        #expect(
            OpenGraphParser.decodeEntities("&nbsp;&ensp;&emsp;&thinsp;|&shy;|&euro;&times;&laquo;&rsquo;")
                == "    ||\u{20AC}\u{D7}\u{AB}\u{2019}")
        #expect(OpenGraphParser.decodeEntities("tail &amp") == "tail &amp")
        #expect(OpenGraphParser.decodeEntities("tail &#12") == "tail &#12")
        #expect(OpenGraphParser.decodeEntities("tail &#x") == "tail &#x")
        #expect(OpenGraphParser.decodeEntities("tail &") == "tail &")
    }
}
