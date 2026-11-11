import KnitWire

/// What a page says about itself, after precedence and hygiene (`PageMeta` in knit-next's `OpenGraphParser.kt`): the
/// title is never blank.
public struct PageMeta: Sendable, Equatable {
    /// The page's title, cleaned and cut to ``LinkPreviewBlob/titleMax``.
    public var title: String
    /// The page's description, cleaned and cut to ``LinkPreviewBlob/descriptionMax``, or `nil` for none or one that only
    /// repeats the title.
    public var description: String?
    /// The page's picture, a plain `https` address resolved against where the fetch ended, or `nil`.
    public var imageURL: String?

    /// Makes one, in Kotlin's declaration order.
    public init(title: String, description: String? = nil, imageURL: String? = nil) {
        self.title = title
        self.description = description
        self.imageURL = imageURL
    }
}

/// A tolerant scanner for the Open Graph, Twitter card and `<title>` metadata of an HTML prefix (`OpenGraphParser.kt` in
/// knit-next, ADR 2026-11.hcvg). It is a port, not a parser of our own, so a card made here reads what Android's reads
/// from the same bytes. Not a DOM: it reads `<meta>` and `<title>` alone, quote-aware, and takes the first of each key.
///
/// Comments, `<script>`, `<style>` and inline `<svg>` are blanked first, so a tag inside a script or a `<title>` inside a
/// drawing is never read. Every text is cleaned as the card's container cleans it (``LinkPreviewBlob/clean(_:limit:)``),
/// and a picture is kept only when it resolves, against the page's final address, to a plain `https` one. It reads the
/// whole prefix it is given, not just the head: enough sites put their tags in the body.
///
/// Kotlin's regexes run on ART, which is ICU: ``ICUText`` reads them as ART does, `\s` and `\w` Unicode-wide and case
/// folded fully, with `find`'s first match and the lazy `.*?`'s nearest close.
public enum OpenGraphParser {
    /// How much of a page the fetcher hands over, 512 KiB: the tags live in the head, which is almost always far smaller.
    public static let maxHTMLBytes = 524_288
    /// A single attribute value longer than this, in UTF-16 units, is cut; no real `content` comes close.
    public static let maxAttributeChars = 4096
    /// How far into the bytes a `<meta charset>` is looked for, as ISO-8859-1, before the page is decoded.
    public static let charsetSniffBytes = 2048
    /// How many picture candidates are tried before the card goes without a picture.
    public static let maxImageCandidates = 3

    /// The page's metadata, or `nil` when it yields no usable title, since a card with only a host is noise (`parse`).
    /// `finalURL` is where the fetch ended after redirects, as the fetch's rules wrote it (``LinkPreviewPolicy/normalize(_:)``
    /// for each hop, as Android's do); a relative picture resolves against it. ART joins a relative picture to a base
    /// with no path without a `/`, so a link written `https://host?query` gets the same broken picture address on both.
    public static func parse(_ html: String, finalURL: String) -> PageMeta? {
        let visible = blanked(ICUText(html))
        var metas = MetaSet()
        var at = 0
        while let open = visible.firstIndex(of: lessThan, from: at) {
            guard let nameEnd = visible.matchCaseless(metaOpen, at: open), visible.isWordBoundary(afterWordAt: nameEnd) else {
                at = open + 1
                continue
            }
            // `findAll` resumes after `<meta`, so a `<meta` inside a quoted value is read as a tag too, as on Android.
            at = nameEnd
            if let attributes = readAttributes(visible, from: nameEnd) {
                metas.add(attributes)
                if metas.isComplete {
                    break
                }
            }
        }
        let titles = [metas.first("og:title"), metas.first("twitter:title"), titleTag(visible)]
        guard let title = firstText(titles, limit: LinkPreviewBlob.titleMax) else {
            return nil
        }
        let descriptions = [metas.first("og:description"), metas.first("twitter:description"), metas.first("description")]
        // Kotlin's `!=` compares UTF-16 units; Swift's would call canonically equivalent texts the same.
        let description = firstText(descriptions, limit: LinkPreviewBlob.descriptionMax).flatMap { text in
            text.utf16.elementsEqual(title.utf16) ? nil : text
        }
        let image = metas.images.prefix(maxImageCandidates).lazy.compactMap { resolveImage($0, base: finalURL) }.first
        return PageMeta(title: title, description: description, imageURL: image)
    }

    /// The first of `candidates` that has text once its entities are decoded and it is cleaned, or `nil` (`firstText`).
    private static func firstText(_ candidates: [String?], limit: Int) -> String? {
        candidates.lazy.compactMap(\.self).map { LinkPreviewBlob.clean(decodeEntities($0), limit: limit) }.first { !$0.isEmpty }
    }

    /// `raw` resolved against `base` and kept only as a plain `https` address, never `data:` and never `http`
    /// (`resolveImage`). Kotlin's `startsWith("https://", ignoreCase = true)` takes `ſ` for `s` as full case folding
    /// does, and ``LinkPreviewBlob/isSafeHttpURL(_:)`` then refuses that scheme on both phones.
    private static func resolveImage(_ raw: String, base: String) -> String? {
        let candidate = TextLimits.trimmed(decodeEntities(raw))
        guard !candidate.isEmpty, candidate.utf16.count <= LinkPreviewBlob.maxURLLength,
            let resolved = JavaURIResolution.resolve(candidate, against: base),
            ICUText(resolved).matchCaseless(httpsPrefix, at: 0) != nil, LinkPreviewBlob.isSafeHttpURL(resolved)
        else {
            return nil
        }
        return resolved
    }

    /// The attributes of the tag whose `<meta` ends at `start`, or `nil` when the tag meets the next `<` or the end of
    /// the text before it closes: a tag cut at the prefix's end is dropped, never guessed at (`readAttributes`). Names
    /// are lower-cased and the first of each kept. A value is cut at ``maxAttributeChars`` UTF-16 units; a cut through a
    /// surrogate pair leaves U+FFFD where Kotlin keeps the lone half, which a Swift string can't hold.
    private static func readAttributes(_ text: ICUText, from start: Int) -> [String: String]? {
        var attributes: [String: String] = [:]
        var at = start
        while let unit = text.unit(at: at) {
            if unit == greaterThan {
                return attributes
            }
            if unit == lessThan {
                return nil
            }
            // Kotlin's `Char.isWhitespace`, on a unit: half of a surrogate pair never is.
            if unit == slash || (Unicode.Scalar(unit).map(TextLimits.isKotlinWhitespace) ?? false) {
                at += 1
                continue
            }
            guard let attribute = attribute(in: text, at: at) else {
                at += 1
                continue
            }
            let name = attribute.name.lowercased()
            if attributes[name] == nil {
                attributes[name] =
                    attribute.value.map { text.string($0.lowerBound..<min($0.upperBound, $0.lowerBound + maxAttributeChars)) } ?? ""
            }
            at = attribute.end
        }
        return nil
    }

    /// One match of `ATTRIBUTE`: the name, where the value sits, if it has one, and where the match ends.
    private struct Attribute {
        var name: String
        var value: Range<Int>?
        var end: Int
    }

    /// `ATTRIBUTE.matchAt(text, start)`, `([A-Za-z_:][-\w:.]*)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?`, or
    /// `nil`. A `=` with no value after it leaves the match at the whitespace after the name, so the scan steps over the
    /// `=` as it would over noise.
    private static func attribute(in text: ICUText, at start: Int) -> Attribute? {
        guard let first = text.unit(at: start), isNameStart(first) else {
            return nil
        }
        let nameEnd = text.skipping(from: start + 1) { nameCharacters.contains($0) || ICUText.isWord($0) }
        let afterName = text.skippingWhitespace(from: nameEnd)
        let name = text.string(start..<nameEnd)
        guard text.unit(at: afterName) == equalsSign,
            let (value, end) = attributeValue(in: text, at: text.skippingWhitespace(from: afterName + 1))
        else {
            return Attribute(name: name, end: afterName)
        }
        return Attribute(name: name, value: value, end: end)
    }

    /// A double-quoted, single-quoted or bare value at `start`, and where it ends, or `nil` when none matches there. A
    /// quoted value runs to its closing quote, past any `>` or `<`; an unclosed one is no value.
    private static func attributeValue(in text: ICUText, at start: Int) -> (Range<Int>, end: Int)? {
        guard let first = text.unit(at: start) else {
            return nil
        }
        if first == doubleQuote || first == singleQuote {
            return text.firstIndex(of: first, from: start + 1).map { (start + 1..<$0, $0 + 1) }
        }
        let end = text.skipping(from: start) { !(TextLimits.isJavaRegexWhitespace($0) || bareValueStops.contains($0)) }
        return end > start ? (start..<end, end) : nil
    }

    /// `[A-Za-z_:]`: setting the case bit lowers an ASCII capital and moves nothing else into `a`...`z`.
    private static func isNameStart(_ unit: UInt16) -> Bool {
        unit == underscore || unit == colon || (lowerA...lowerZ).contains(unit | caseBit)
    }

    /// The first `<title>`'s raw text, entities and all, or `nil` (`TITLE.find`).
    private static func titleTag(_ text: ICUText) -> String? {
        var searches = ElementSearches()
        var at = 0
        while let open = text.firstIndex(of: lessThan, from: at) {
            if let element = element(.title, at: open, in: text, &searches) {
                return text.string(element.content)
            }
            at = open + 1
        }
        return nil
    }

    /// The metas seen so far, the first of each key, and the picture candidates in their order and precedence
    /// (`MetaSet`). Keys are compared as Swift strings: none that is looked up has another canonically equivalent form.
    private struct MetaSet {
        private var firsts: [String: String] = [:]
        private var secureImages: [String] = []
        private var openGraphImages: [String] = []
        private var twitterImages: [String] = []

        /// Takes a tag's `content` under its `property`, or its `name` when it has no `property`, trimmed and lower-cased.
        mutating func add(_ attributes: [String: String]) {
            guard let key = (attributes["property"] ?? attributes["name"]).map({ TextLimits.trimmed($0).lowercased() }),
                let content = attributes["content"]
            else {
                return
            }
            switch key {
            case "og:image:secure_url":
                secureImages.append(content)
            case "og:image", "og:image:url":
                openGraphImages.append(content)
            case "twitter:image", "twitter:image:src":
                twitterImages.append(content)
            default:
                if firsts[key] == nil {
                    firsts[key] = content
                }
            }
        }

        /// The first content seen under `key`.
        func first(_ key: String) -> String? {
            firsts[key]
        }

        /// The picture candidates: secure ones first, then Open Graph's, then Twitter's.
        var images: [String] { secureImages + openGraphImages + twitterImages }

        /// Once the three top-precedence keys are all present, nothing later can change the outcome (`complete`).
        var isComplete: Bool {
            firsts["og:title"] != nil && firsts["og:description"] != nil && !(secureImages.isEmpty && openGraphImages.isEmpty)
        }
    }

    /// `<`, where every tag starts.
    static let lessThan = UInt16(UInt8(ascii: "<"))
    /// `>`, where a tag ends.
    static let greaterThan = UInt16(UInt8(ascii: ">"))
    /// `=`, between a name and its value.
    static let equalsSign = UInt16(UInt8(ascii: "="))
    /// `"`, around a value.
    static let doubleQuote = UInt16(UInt8(ascii: "\""))
    /// `'`, around a value.
    static let singleQuote = UInt16(UInt8(ascii: "'"))
    /// `<meta`, matched without regard to case.
    static let metaOpen = Array("<meta".utf8)
    private static let slash = UInt16(UInt8(ascii: "/"))
    private static let underscore = UInt16(UInt8(ascii: "_"))
    private static let colon = UInt16(UInt8(ascii: ":"))
    private static let lowerA = UInt16(UInt8(ascii: "a"))
    private static let lowerZ = UInt16(UInt8(ascii: "z"))
    /// The bit between an ASCII capital and its small letter.
    private static let caseBit: UInt16 = 0x20
    private static let httpsPrefix = Array("https://".utf8)
    /// What a name holds besides `\w`: `[-\w:.]`.
    private static let nameCharacters: Set<Unicode.Scalar> = ["-", ":", "."]
    /// What ends a bare value besides `\s`: `[^\s"'=<>`]`.
    private static let bareValueStops: Set<Unicode.Scalar> = ["\"", "'", "=", "<", ">", "`"]
}
