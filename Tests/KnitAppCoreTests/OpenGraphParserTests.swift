import KnitWire
import Testing

@testable import KnitAppCore

/// What a page's metadata reads as: every case of knit-next's `OpenGraphParserTest.kt`, then the places where ART's
/// ICU regexes read a page differently from the desktop JDK that test runs on, and the ported rules' edges.
@Suite struct OpenGraphParserTests {
    private let page = "https://example.com/articles/one"

    private func parse(_ html: String) -> PageMeta? {
        OpenGraphParser.parse(html, finalURL: page)
    }

    // MARK: - OpenGraphParserTest.kt

    @Test func openGraphOutranksTwitterWhichOutranksTheTitleTag() throws {
        let html = """
            <html><head><title>Tag title</title>
            <meta name="twitter:title" content="Twitter title">
            <meta property="og:title" content="OG title">
            <meta name="twitter:description" content="Twitter desc">
            <meta property="og:description" content="OG desc">
            <meta name="description" content="Plain desc">
            </head><body></body></html>
            """
        let meta = try #require(parse(html))
        #expect(meta.title == "OG title")
        #expect(meta.description == "OG desc")
        #expect(try #require(parse(html.replacing(#"<meta property="og:title" content="OG title">"#, with: ""))).title == "Twitter title")
        let onlyTag = try #require(parse("<title>Tag title</title><meta name=description content='Plain desc'>"))
        #expect(onlyTag.title == "Tag title")
        #expect(onlyTag.description == "Plain desc")
    }

    @Test func aPageWithoutATitleYieldsNoCardAndADescriptionEqualToTheTitleIsDropped() throws {
        #expect(parse(#"<html><head><meta property="og:description" content="desc only"></head></html>"#) == nil)
        #expect(parse("<title>   </title>") == nil)
        let same = try #require(parse("<meta property='og:title' content='Same'><meta property='og:description' content='Same'>"))
        #expect(same.description == nil)
    }

    @Test func attributesAreReadInAnyOrderQuoteStyleAndCase() throws {
        let html = """
            <META CONTENT="Reversed" PROPERTY="og:title"/>
            <meta content='single "quoted" desc' property='og:description'>
            <meta property=og:image content=https://cdn.example.com/bare.jpg>
            """
        let meta = try #require(parse(html))
        #expect(meta.title == "Reversed")
        #expect(meta.description == "single \"quoted\" desc")
        #expect(meta.imageURL == "https://cdn.example.com/bare.jpg")
    }

    @Test func aGreaterThanInsideAQuotedValueDoesNotEndTheTag() throws {
        let meta = try #require(parse(#"<meta property="og:title" content="a > b > c"><meta property="og:description" content="d">"#))
        #expect(meta.title == "a > b > c")
        #expect(meta.description == "d")
    }

    @Test func theFirstOccurrenceOfAKeyWinsAndAnUnclosedTrailingTagIsDropped() throws {
        let meta = try #require(
            parse(#"<meta property="og:title" content="First"><meta property="og:title" content="Second"><meta property="og:desc"#))
        #expect(meta.title == "First")
        #expect(meta.description == nil)
    }

    @Test func scriptsStylesCommentsAndInlineSvgAreNeverReadAsTags() throws {
        let html = """
            <script>var s = '<meta property="og:title" content="from script">';</script>
            <style>/* <meta property="og:title" content="from style"> */</style>
            <!-- <meta property="og:title" content="from comment"> -->
            <svg><title>drawing title</title></svg>
            <title>Real title</title>
            """
        #expect(try #require(parse(html)).title == "Real title")
    }

    @Test func entitiesAreDecodedAndUnknownNamesStayLiteral() throws {
        let html = #"<meta property="og:title" content="Fish &amp; Chips &#39;n&#x27; &quot;more&quot; &nbsp;&mdash; &bogus; &#128512;">"#
        #expect(try #require(parse(html)).title == "Fish & Chips 'n' \"more\" \u{2014} &bogus; \u{1F600}")
        #expect(OpenGraphParser.decodeEntities("&lt;&gt;") == "<>")
        #expect(OpenGraphParser.decodeEntities("&#xD800;&#0;") == "&#xD800;&#0;")
    }

    @Test func textIsCleanedAndCappedLikeTheContainerDoes() throws {
        let html = "<meta property=\"og:title\" content=\"  Read \u{202E}this\u{200B} now\t\tplease  \">"
        #expect(try #require(parse(html)).title == "Read this now please")
        let long = "<meta property=\"og:title\" content=\"\(String(repeating: "t", count: LinkPreviewBlob.titleMax + 10))\">"
        #expect(try #require(parse(long)).title.utf16.count == LinkPreviewBlob.titleMax)
    }

    @Test func aPictureResolvesAgainstThePagesFinalUrlAndMustBeHttps() throws {
        let relative = try #require(parse(#"<title>T</title><meta property="og:image" content="../img/pic.jpg">"#))
        #expect(relative.imageURL == "https://example.com/img/pic.jpg")
        let protocolRelative = try #require(parse(#"<title>T</title><meta property="og:image" content="//cdn.example.com/p.png">"#))
        #expect(protocolRelative.imageURL == "https://cdn.example.com/p.png")
        let http = try #require(parse(#"<title>T</title><meta property="og:image" content="http://cdn.example.com/p.png">"#))
        #expect(http.imageURL == nil)
        let data = try #require(parse(#"<title>T</title><meta property="og:image" content="data:image/png;base64,AAAA">"#))
        #expect(data.imageURL == nil)
    }

    @Test func theSecureImageIsPreferredThenOpenGraphThenTwitterAndOnlyAFewCandidatesAreTried() throws {
        let html = """
            <title>T</title>
            <meta name="twitter:image" content="https://cdn.example.com/tw.jpg">
            <meta property="og:image" content="http://cdn.example.com/insecure.jpg">
            <meta property="og:image:secure_url" content="https://cdn.example.com/secure.jpg">
            """
        #expect(try #require(parse(html)).imageURL == "https://cdn.example.com/secure.jpg")
        let noneSafe = """
            <title>T</title>
            <meta property="og:image" content="http://a.example/1.jpg">
            <meta property="og:image" content="data:x">
            <meta property="og:image" content="ftp://a.example/3.jpg">
            <meta property="og:image" content="https://a.example/4.jpg">
            """
        #expect(try #require(parse(noneSafe)).imageURL == nil)
        let third = """
            <title>T</title>
            <meta property="og:image" content="http://a.example/1.jpg">
            <meta property="og:image" content="data:x">
            <meta property="og:image" content="https://a.example/3.jpg">
            """
        #expect(try #require(parse(third)).imageURL == "https://a.example/3.jpg")
    }

    @Test func tagsInTheBodyAndAfterALongPreambleAreStillFound() throws {
        let preamble = "<div>" + String(repeating: "x", count: 300 * 1024) + "</div>"
        let html = "<html><head></head><body>\(preamble)<meta property=\"og:title\" content=\"Late\"></body></html>"
        #expect(try #require(parse(html)).title == "Late")
    }

    // MARK: - ART's regexes

    /// ART's `CASE_INSENSITIVE` folds case Unicode-wide (`Pattern.java`, android-37.2), so a long s opens a script and
    /// a ligature a style, which the desktop JDK's ASCII folding would read as text.
    @Test func caseFoldingIsUnicodesAsOnART() throws {
        let html = """
            <SCRIPT>x</SCRIPT><\u{17F}cript><meta property="og:title" content="from a script"></\u{17F}CRIPT>
            <\u{FB06}yle><meta property="og:title" content="from a style"></STYLE>
            <svG><meta property="og:title" content="from a drawing"></Svg>
            <TITLE>Folded</TITLE>
            """
        #expect(try #require(parse(html)).title == "Folded")
        // U+0130 folds to `i` and a combining dot, which the pattern's `p` never matches.
        #expect(parse("<scr\u{130}pt><meta property=\"og:title\" content=\"Read\"></script>")?.title == "Read")
    }

    /// `\b` after a tag's name is ICU's: a word character, a combining mark or a format character joins the name, and
    /// anything else ends it, a `-` included.
    @Test func aTagNameEndsWhereICUSeesAWordBoundary() throws {
        #expect(try #require(parse(#"<meta-x property="og:title" content="Dashed">"#)).title == "Dashed")
        #expect(parse(#"<metadata property="og:title" content="Longer name">"#) == nil)
        #expect(parse("<meta\u{301} property=\"og:title\" content=\"Mark\">") == nil)
        #expect(parse("<meta\u{200B} property=\"og:title\" content=\"Format\">") == nil)
        #expect(parse("<meta\u{1D400} property=\"og:title\" content=\"Letter past the BMP\">") == nil)
        #expect(try #require(parse("<meta\u{A0}property=\"og:title\" content=\"Space\">")).title == "Space")
        // The end of the text is a boundary too, and a tag cut there, even right after a `=`, is dropped.
        #expect(try #require(parse("<title>Cut tags</title><meta")).title == "Cut tags")
        #expect(try #require(parse("<title>Cut tags</title><meta property=")).title == "Cut tags")
        #expect(try #require(parse("<scripts><title>Inside</title></scripts>")).title == "Inside")
        #expect(try #require(parse("<script\u{2028}><title>Inside</title></script><title>After</title>")).title == "After")
    }

    /// A block that never closes is no match, so it stays and is read; a closing tag may hold `\s` before its `>`.
    @Test func aBlockClosesAtItsFirstClosingTagOrNotAtAll() throws {
        #expect(try #require(parse(#"<script><meta property="og:title" content="Unclosed script">"#)).title == "Unclosed script")
        let twoComments = #"<!-- one <!-- two <meta property="og:title" content="Unclosed comments">"#
        #expect(try #require(parse(twoComments)).title == "Unclosed comments")
        #expect(try #require(parse(#"<!--><meta property="og:title" content="Hidden">--><title>Shown</title>"#)).title == "Shown")
        let spaced = "<script><title>A</title></script\u{2028} ><script ><title>B</title></scriptx></script\n><title>Spaced</title>"
        #expect(try #require(parse(spaced)).title == "Spaced")
        #expect(try #require(parse("<title lang=\"en\">A &amp; B</title\t>")).title == "A & B")
        #expect(parse("<title>Never closed") == nil)
        #expect(parse("<title Never opened</title>") == nil)
    }

    // MARK: - Attributes

    @Test func aValuelessAttributeOrAStrayEqualsSignIsReadAsTheRegexReadsIt() throws {
        #expect(try #require(parse(#"<meta itemprop property="og:title" content="Valueless">"#)).title == "Valueless")
        #expect(try #require(parse(#"<meta property=><title>No value</title>"#)).title == "No value")
        // `=` then whitespace takes the next name as a bare value, so this tag has a `property` of `content`.
        #expect(parse(#"<meta property= content="X">"#) == nil)
        // An unclosed quote is no value; the scan steps into it and reads what follows as names.
        #expect(parse(#"<meta property="og:title content=X>"#) == nil)
        #expect(try #require(parse(#"<meta \#u{1F600} property=og:title content=Caf\#u{E9}\#u{1F600}>"#)).title == "Caf\u{E9}\u{1F600}")
        #expect(try #require(parse(#"<meta property=" OG:Title " content="Trimmed">"#)).title == "Trimmed")
        #expect(parse(#"<meta property="" name="og:title" content="An empty property wins">"#) == nil)
        #expect(parse(#"<meta property="og:title" content="Opened" <title>Cut</title>"#)?.title == "Cut")
        #expect(try #require(parse(#"<meta Content="Names fold" PROPERTY="og:title" content="Second">"#)).title == "Names fold")
        // `\w` is Unicode-wide, so `propertyé` is one name; read as ASCII, an empty `property` would come first.
        #expect(try #require(parse(#"<meta property\#u{E9}="x" property="og:title" content="Wide name">"#)).title == "Wide name")
    }

    /// `take(MAX_ATTRIBUTE_CHARS)` cuts a value at 4,096 UTF-16 units, before the text is cleaned. A cut through a surrogate
    /// pair leaves U+FFFD here, where Kotlin keeps the lone half.
    @Test func aValueIsCutAtTheAttributeLimitBeforeItIsCleaned() throws {
        let spaces = String(repeating: " ", count: OpenGraphParser.maxAttributeChars - 2)
        #expect(try #require(parse("<meta property=\"og:title\" content=\"\(spaces)abcd\">")).title == "ab")
        let pair = "<meta property=\"og:title\" content=\"\(spaces) \u{1F600}\">"
        #expect(try #require(parse(pair)).title == "\u{FFFD}")
    }

    /// `findAll` resumes right after each `<meta`, so a `<meta` inside an earlier tag's quoted value is a tag too.
    @Test func aMetaInsideAQuotedValueIsReadToo() throws {
        let meta = try #require(parse(#"<meta content="<meta property='og:title' content='Inner'>" property="og:description">"#))
        #expect(meta.title == "Inner")
        #expect(meta.description == "<meta property='og:title' content='Inner'>")
    }

    /// Once the title, the description and an Open Graph picture are in, the scan stops, so a secure picture after them
    /// is never read (`complete`).
    @Test func theScanStopsOnceTheTopKeysAreIn() throws {
        let html = """
            <meta property="og:title" content="T"><meta property="og:description" content="D">
            <meta property="og:image" content="http://a.example/insecure.jpg">
            <meta property="og:image:secure_url" content="https://a.example/secure.jpg">
            """
        #expect(try #require(parse(html)).imageURL == nil)
        let urlKeys = """
            <title>T</title><meta property="og:image:url" content="data:x">
            <meta name="twitter:image:src" content=" https://a.example/a.jpg?x=1&amp;y=2 ">
            """
        #expect(try #require(parse(urlKeys)).imageURL == "https://a.example/a.jpg?x=1&y=2")
    }

    @Test func aPictureAddressIsDecodedTrimmedBoundedAndThenResolved() throws {
        let long = "https://a.example/" + String(repeating: "a", count: LinkPreviewBlob.maxURLLength)
        let candidates = """
            <title>T</title><meta property="og:image" content="  "><meta property="og:image" content="\(long)">
            <meta property="og:image" content="https://a.example/[x].jpg">
            """
        #expect(try #require(parse(candidates)).imageURL == nil)
        #expect(parse("<title>T</title><meta property=og:image content=/p.jpg>")?.imageURL == "https://example.com/p.jpg")
        let unsafe = #"<title>T</title><meta property="og:image" content="https://user@a.example/p.jpg">"#
        #expect(parse(unsafe)?.imageURL == nil)
        #expect(
            parse(#"<title>T</title><meta property="og:image" content="HTTPS://A.example/p.jpg">"#)?.imageURL == "HTTPS://A.example/p.jpg")
    }

    /// ART joins a relative picture to a base with no path without a `/`, as Android does when the link was
    /// `https://host?query`; the card's picture address names another host, and the fetch of it fails.
    @Test func aRelativePictureAgainstABaseWithNoPathJoinsWithoutASlashAsOnART() throws {
        let meta = OpenGraphParser.parse(
            #"<title>T</title><meta property="og:image" content="img.jpg">"#, finalURL: "https://example.com?q=1")
        #expect(try #require(meta).imageURL == "https://example.comimg.jpg")
    }

    @Test func aDescriptionIsComparedWithTheTitleUnitByUnit() throws {
        let meta = try #require(
            parse("<meta property=og:title content=\"Caf\u{E9}\"><meta property=og:description content=\"Cafe\u{301}\">"))
        #expect(meta.description?.unicodeScalars.elementsEqual("Cafe\u{301}".unicodeScalars) == true)
    }
}
