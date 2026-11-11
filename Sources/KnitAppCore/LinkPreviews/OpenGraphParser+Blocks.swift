import KnitWire

/// The blocks the parser reads whole: the comments, scripts, styles and drawings it blanks, and `<title>`.
extension OpenGraphParser {
    /// An element whose inside is one block, `<name\b[^>]*>.*?</name\s*>`, by its name.
    enum Element {
        case script, style, svg, title

        /// `<name`, matched without regard to case.
        var opening: [UInt8] { Array("<\(name)".utf8) }
        /// `</name`, matched without regard to case.
        var closing: [UInt8] { Array("</\(name)".utf8) }

        private var name: String {
            switch self {
            case .script:
                "script"
            case .style:
                "style"
            case .svg:
                "svg"
            case .title:
                "title"
            }
        }
    }

    /// A block: what lies between its tag's `>` and its closing tag, and where the closing tag ends.
    typealias Block = (content: Range<Int>, end: Int)

    /// `BLANKED.replace(html, " ")`: each comment, script, style and inline drawing becomes one space, so nothing inside
    /// one is read as a tag (`<!--.*?-->|<script\b[^>]*>.*?</script\s*>|<style\b…|<svg\b…`, case folded, `.` taking line
    /// ends too). One that never closes is left as it is, as a pattern that can't match there leaves it.
    static func blanked(_ text: ICUText) -> ICUText {
        var kept: [UInt16] = []
        kept.reserveCapacity(text.count)
        var searches = ElementSearches()
        var copied = 0
        var at = 0
        while let open = text.firstIndex(of: lessThan, from: at) {
            guard let end = blockEnd(at: open, in: text, &searches) else {
                at = open + 1
                continue
            }
            kept += text.units[copied..<open]
            kept.append(space)
            copied = end
            at = end
        }
        kept += text.units[copied...]
        return ICUText(units: kept)
    }

    /// Where the block that opens at `open` ends, or `nil` when none opens there or it never closes. The alternatives
    /// open differently, so at most one can match at a point, and ICU's order among them never matters.
    private static func blockEnd(at open: Int, in text: ICUText, _ searches: inout ElementSearches) -> Int? {
        if let bodyStart = text.matchCaseless(commentOpen, at: open) {
            return searches.commentClose.next(from: bodyStart) { commentClose(in: text, from: $0) }?.upperBound
        }
        for candidate in [Element.script, .style, .svg] {
            if let found = element(candidate, at: open, in: text, &searches) {
                return found.end
            }
        }
        return nil
    }

    /// `element` opening at `open`: what lies between its tag's `>` and its closing tag, and where the closing tag ends,
    /// or `nil`. The tag ends at its first `>` (`[^>]*>`), and the closing tag is the first after it (`.*?`). `\b` keeps
    /// `<scripts>` and `<titled>` from opening one.
    static func element(_ element: Element, at open: Int, in text: ICUText, _ searches: inout ElementSearches) -> Block? {
        guard let nameEnd = text.matchCaseless(element.opening, at: open), text.isWordBoundary(afterWordAt: nameEnd),
            let tagEnd = searches.tagEnd.next(from: nameEnd, { text.firstIndex(of: greaterThan, from: $0).map { $0..<$0 + 1 } }),
            let close = searches.closes[element, default: ForwardSearch()].next(
                from: tagEnd.upperBound, { closingTag(element, in: text, from: $0) })
        else {
            return nil
        }
        return (tagEnd.upperBound..<close.lowerBound, close.upperBound)
    }

    /// The first `</name\s*>` at or after `start`.
    private static func closingTag(_ element: Element, in text: ICUText, from start: Int) -> Range<Int>? {
        var at = start
        while let open = text.firstIndex(of: lessThan, from: at) {
            if let nameEnd = text.matchCaseless(element.closing, at: open) {
                let end = text.skippingWhitespace(from: nameEnd)
                if text.unit(at: end) == greaterThan {
                    return open..<end + 1
                }
            }
            at = open + 1
        }
        return nil
    }

    /// The first `-->` at or after `start`.
    private static func commentClose(in text: ICUText, from start: Int) -> Range<Int>? {
        var at = start
        while let dash = text.firstIndex(of: hyphen, from: at) {
            if let end = text.matchCaseless(commentEnd, at: dash) {
                return dash..<end
            }
            at = dash + 1
        }
        return nil
    }

    /// The searches one pass over a text makes, each kept so the pass stays linear.
    struct ElementSearches {
        /// The next `>`.
        var tagEnd = ForwardSearch()
        /// The next `-->`.
        var commentClose = ForwardSearch()
        /// The next closing tag of each element.
        var closes: [Element: ForwardSearch] = [:]
    }

    /// A search for the first match at or after a point, its last answer kept for the next search from a point no
    /// earlier: the answer holds while it lies at or after the new point, and none stays none. ICU searches the rest of
    /// the page again from each tag that never closes; keeping the answer gives the same matches in linear time.
    struct ForwardSearch {
        private var start = Int.max
        private var found: Range<Int>?

        /// The first match at or after `point`, from `search` or from the kept answer.
        mutating func next(from point: Int, _ search: (Int) -> Range<Int>?) -> Range<Int>? {
            if point >= start, found.map({ $0.lowerBound >= point }) ?? true {
                return found
            }
            start = point
            found = search(point)
            return found
        }
    }

    private static let commentOpen = Array("<!--".utf8)
    private static let commentEnd = Array("-->".utf8)
    private static let hyphen = UInt16(UInt8(ascii: "-"))
    private static let space = UInt16(UInt8(ascii: " "))
}
