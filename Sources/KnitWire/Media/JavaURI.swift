/// What `java.net.URI`'s constructor finds in an address on ART (`URI.java`, android-37.2, the `Parser` class), or `nil`
/// where it throws. A link card's address is judged by the scheme, the raw user-info and the host
/// (``LinkPreviewBlob/isSafeHttpURL(_:)``); a page's picture is resolved from every part (``JavaURIResolution``).
///
/// It is a port, not a URL parser of our own, so the iPhone keeps and refuses the same card addresses Android does. It
/// walks UTF-16 units as Java's `charAt` does, with Java's character classes (RFC 2396 plus Java's deviations: an empty
/// path, an underscore in a host label). An authority that is no server is a registry name, with no host, which is how
/// `https://bücher.de/` reads on Android.
///
/// One deviation: an IPv6 literal (`[…]`) throws here, where Java would parse it. No Android sender writes one into a
/// card (`LinkPreviewPolicy` refuses it), so only a hand-made card meets the difference, and it is refused.
internal struct JavaURI {
    /// The scheme as written, case kept, or `nil` for a relative reference.
    var scheme: String?
    /// The raw authority after `//`, a server or a registry name, or `nil` for none. An empty one (`file:///a`) is none.
    var authority: String?
    /// The raw user-info before an `@`, or `nil` when there is none. An empty one (`https://@host`) is not `nil`.
    var userInfo: String?
    /// The host as written, or `nil` for a registry-based or missing authority.
    var host: String?
    /// The port as `Integer.parseInt` read it, so `:0443` is 443, or -1 for none (`https://host:/` has none).
    var port = -1
    /// The raw path, empty when there is none, or `nil` for an opaque URI (`mailto:a@b.example`), Java's `isOpaque()`.
    /// Nothing reads an opaque URI's scheme-specific part: `resolve` hands one back whole, with its ``string``.
    var path: String?
    /// The raw query after `?`, or `nil` for none. An empty one (`?`) is not `nil`.
    var query: String?
    /// The raw fragment after `#`, or `nil` for none.
    var fragment: String?
    /// The text this was parsed from, which `toString()` hands back as it is, or `nil` for one that `resolve` built.
    var string: String?

    /// `text` parsed as ART's `new URI(text)` parses it, or `nil` where that throws.
    init?(_ text: String) {
        var parser = Parser(units: Array(text.utf16))
        do {
            try parser.parse()
        } catch {
            return nil
        }
        self = parser.uri
        string = text
    }

    /// Java's `new URI()`, for the parser to fill in.
    init() {
        // Every part starts undefined: `nil`, and -1 for the port.
    }
}

/// `URISyntaxException`, whatever its reason.
private struct Malformed: Error {}

/// ART's `URI.Parser`, its methods kept under Java's names where they read the same.
private struct Parser {
    let units: [UInt16]
    /// What the parser has found so far, the fields Java's `Parser` sets on its `URI`.
    var uri = JavaURI()

    private var count: Int { units.count }

    init(units: [UInt16]) {
        self.units = units
    }

    /// `parse(false)`: `[scheme:]scheme-specific-part[#fragment]`.
    mutating func parse() throws(Malformed) {
        var at = scan(0, count, error: "/?#", stop: ":")
        if at >= 0, self.at(at, count, ":") {
            guard at > 0 else {
                throw Malformed()
            }
            try checkChars(0, 1, .alpha)
            try checkChars(1, at, .scheme)
            uri.scheme = substring(0, at)
            at += 1
            if self.at(at, count, "/") {
                at = try parseHierarchical(at, count)
            } else {
                let end = scan(at, count, error: "", stop: "#")
                guard end > at else {
                    throw Malformed()
                }
                try checkChars(at, end, .uric)
                at = end
            }
        } else {
            at = try parseHierarchical(0, count)
        }
        if self.at(at, count, "#") {
            try checkChars(at + 1, count, .uric)
            uri.fragment = substring(at + 1, count)
            at = count
        }
        guard at >= count else {
            throw Malformed()
        }
    }

    /// `[//authority]path[?query]`, the path allowed to be empty (Java's deviation).
    private mutating func parseHierarchical(_ start: Int, _ end: Int) throws(Malformed) -> Int {
        var at = start
        if self.at(at, end, "/"), self.at(at + 1, end, "/") {
            at += Self.authorityMarkLength
            let authorityEnd = scan(at, end, error: "", stop: "/?#")
            if authorityEnd > at {
                at = try parseAuthority(at, authorityEnd)
            } else if authorityEnd >= end {
                throw Malformed()
            }
        }
        let pathEnd = scan(at, end, error: "", stop: "?#")
        try checkChars(at, pathEnd, .path)
        uri.path = substring(at, pathEnd)
        at = pathEnd
        if self.at(at, end, "?") {
            at += 1
            let queryEnd = scan(at, end, error: "", stop: "#")
            try checkChars(at, queryEnd, .uric)
            uri.query = substring(at, queryEnd)
            at = queryEnd
        }
        return at
    }

    /// A server (`[userinfo@]host[:port]`) when it parses as one, else a registry name, which has no host.
    private mutating func parseAuthority(_ start: Int, _ end: Int) throws(Malformed) -> Int {
        // Java tests "a `]` found past the start" with a scan that stops at the first `]`, which holds for almost any
        // authority; ported as written.
        let serverMask: JavaURIMask = scan(start, end, error: "", stop: "]") > start ? .serverPercent : .server
        let serverChars = try scan(start, end, serverMask) == end
        let registryChars = try scan(start, end, .registryName) == end
        // Java first returns a registry name whose characters are no server's, which never happens: every registry
        // character is a server character too.
        var parsed = start
        var failure: Malformed?
        if serverChars {
            do throws(Malformed) {
                parsed = try parseServer(start, end)
                if parsed < end {
                    throw Malformed()
                }
            } catch {
                uri.userInfo = nil
                uri.host = nil
                uri.port = -1
                failure = error
                parsed = start
            }
        }
        if parsed < end, !registryChars {
            throw failure ?? Malformed()
        }
        // Every way out that does not throw keeps the whole authority, a server's or a registry name.
        uri.authority = substring(start, end)
        return end
    }

    /// `[userinfo@]host[:port]`, all of `start..<end`.
    private mutating func parseServer(_ start: Int, _ end: Int) throws(Malformed) -> Int {
        var at = start
        let atSign = scan(at, end, error: "/?#", stop: "@")
        if atSign >= at, self.at(atSign, end, "@") {
            try checkChars(at, atSign, .userInfo)
            uri.userInfo = substring(at, atSign)
            at = atSign + 1
        }
        if self.at(at, end, "[") {
            throw Malformed() // An IPv6 literal: see the type's note.
        }
        var hostEnd = parseIPv4Address(at, end)
        if hostEnd <= at {
            hostEnd = try parseHostname(at, end)
        }
        at = hostEnd
        if self.at(at, end, ":") {
            at += 1
            let portEnd = scan(at, end, error: "", stop: "/")
            if portEnd > at {
                try checkChars(at, portEnd, .digit)
                // Java's `Integer.parseInt`: past `Int32.max` it throws.
                guard let port = Int32(substring(at, portEnd)) else {
                    throw Malformed()
                }
                uri.port = Int(port)
                at = portEnd
            }
        }
        guard at >= end else {
            throw Malformed()
        }
        return at
    }

    /// A dotted IPv4 address followed by the end or a `:`, its end, or a value at or before `start` when it is not one.
    private mutating func parseIPv4Address(_ start: Int, _ end: Int) -> Int {
        guard var at = try? scanIPv4Address(start, end) else {
            return -1
        }
        if at > start, at < end, units[at] != Self.colon {
            at = -1
        }
        if at > start {
            uri.host = substring(start, at)
        }
        return at
    }

    private func scanIPv4Address(_ start: Int, _ end: Int) throws(Malformed) -> Int {
        let digitsEnd = (try? scan(start, end, .digit | .dot)) ?? start
        guard digitsEnd > start else {
            return -1
        }
        var at = start
        for octet in 0..<Self.octets {
            if octet > 0 {
                let dotEnd = scanUnit(at, digitsEnd, Self.dot)
                guard dotEnd > at else {
                    throw Malformed()
                }
                at = dotEnd
            }
            let byteEnd = try scanByte(at, digitsEnd)
            guard byteEnd > at else {
                throw Malformed()
            }
            at = byteEnd
        }
        guard at >= digitsEnd else {
            throw Malformed()
        }
        return at
    }

    /// One decimal octet: its end, or `start` when it is past 255. A run past `Int32` throws, as `parseInt` does.
    private func scanByte(_ start: Int, _ end: Int) throws(Malformed) -> Int {
        let digitsEnd = (try? scan(start, end, .digit)) ?? start
        guard digitsEnd > start else {
            return digitsEnd
        }
        guard let value = Int32(substring(start, digitsEnd)) else {
            throw Malformed()
        }
        return value > Self.maxOctet ? start : digitsEnd
    }

    /// Labels of letters, digits, dashes and underscores, each starting with a letter or digit and not ending with a
    /// dash, separated by dots; the last label starts with a letter unless it is the only one.
    private mutating func parseHostname(_ start: Int, _ end: Int) throws(Malformed) -> Int {
        var at = start
        var lastLabel = -1
        repeat {
            var next = (try? scan(at, end, .alphanumeric)) ?? at
            if next <= at {
                break
            }
            lastLabel = at
            at = next
            next = (try? scan(at, end, .alphanumeric | .dash | .underscore)) ?? at
            if next > at {
                guard units[next - 1] != Self.dashUnit else {
                    throw Malformed()
                }
                at = next
            }
            next = scanUnit(at, end, Self.dot)
            if next <= at {
                break
            }
            at = next
        } while at < end
        if at < end, !self.at(at, end, ":") {
            throw Malformed()
        }
        guard lastLabel >= 0 else {
            throw Malformed()
        }
        if lastLabel > start, !JavaURIMask.alpha.matches(units[lastLabel]) {
            throw Malformed()
        }
        uri.host = substring(start, at)
        return at
    }
}

// Java's scanning helpers.
extension Parser {
    private func at(_ start: Int, _ end: Int, _ character: Unicode.Scalar) -> Bool {
        start < end && units[start] == UInt16(character.value)
    }

    /// `scan(start, end, char)`: one past `unit` when it is next, else `start`.
    private func scanUnit(_ start: Int, _ end: Int, _ unit: UInt16) -> Int {
        start < end && units[start] == unit ? start + 1 : start
    }

    /// `scan(start, end, err, stop)`: where the first `stop` unit is (or `end`), or -1 when an `error` unit comes first.
    private func scan(_ start: Int, _ end: Int, error: String, stop: String) -> Int {
        var at = start
        while at < end {
            let unit = units[at]
            if error.utf16.contains(unit) {
                return -1
            }
            if stop.utf16.contains(unit) {
                break
            }
            at += 1
        }
        return at
    }

    /// `scan(start, end, lowMask, highMask)`: past every unit the mask takes, and, where it takes escapes, past each
    /// `%XX` and each other character. A `%` without two hex digits throws there.
    private func scan(_ start: Int, _ end: Int, _ mask: JavaURIMask) throws(Malformed) -> Int {
        var at = start
        while at < end {
            let unit = units[at]
            if mask.matches(unit) {
                at += 1
                continue
            }
            if mask.allowsEscapes {
                let escaped = try scanEscape(at, end, unit)
                if escaped > at {
                    at = escaped
                    continue
                }
            }
            break
        }
        return at
    }

    /// `scanEscape`: past a `%XX` triplet or one other character (past U+0080, not a space and not a control).
    private func scanEscape(_ start: Int, _ end: Int, _ first: UInt16) throws(Malformed) -> Int {
        if first == Self.percent {
            guard start + Self.escapeLength <= end, JavaURIMask.hex.matches(units[start + 1]),
                JavaURIMask.hex.matches(units[start + Self.escapeLength - 1])
            else {
                throw Malformed()
            }
            return start + Self.escapeLength
        }
        if first > Self.firstOther, !JavaChar.isSpaceChar(first), !JavaChar.isISOControl(first) {
            return start + 1
        }
        return start
    }

    private func checkChars(_ start: Int, _ end: Int, _ mask: JavaURIMask) throws(Malformed) {
        if try scan(start, end, mask) < end {
            throw Malformed()
        }
    }

    private func substring(_ start: Int, _ end: Int) -> String {
        String(decoding: units[start..<end], as: UTF16.self)
    }

    private static let colon = UInt16(UInt8(ascii: ":"))
    private static let dot = UInt16(UInt8(ascii: "."))
    private static let dashUnit = UInt16(UInt8(ascii: "-"))
    private static let percent = UInt16(UInt8(ascii: "%"))
    /// `%` and two hex digits.
    private static let escapeLength = 3
    /// The `//` before an authority.
    private static let authorityMarkLength = 2
    private static let octets = 4
    private static let maxOctet: Int32 = 255
    /// Java tests `c > 128`, so U+0080 itself, a control, is never other.
    private static let firstOther: UInt16 = 128
}
