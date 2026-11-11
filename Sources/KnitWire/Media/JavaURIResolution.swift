/// `java.net.URI.resolve` as ART runs it (`URI.java`, android-37.2): a reference resolved against a base, and the result
/// written as `toString()` writes it. A link card's picture is an address on the page, resolved against where the page's
/// fetch ended (`resolveImage` in knit-next's `OpenGraphParser.kt`), so the iPhone takes the pictures Android takes.
///
/// It follows ART where ART departs from OpenJDK (http://b/25897693), which reads RFC 3986's rules into RFC 2396's:
/// - a reference with an empty path keeps the base's path, and the base's query unless it has its own
///   (`?y` against `http://a/b/c/d;p?q` is `http://a/b/c/d;p?y`, where OpenJDK 21 writes `http://a/b/c/?y`);
/// - dot segments leave an absolute reference's path too, and a `..` with nothing left to remove is dropped
///   (`../../../g` there is `http://a/g`, where OpenJDK keeps `http://a/../g`).
///
/// ART also keeps the old rule that a relative path joins a base with no path at all directly, with no `/` between:
/// `img.jpg` against `https://example.com` is `https://example.comimg.jpg`, where OpenJDK 21 puts the `/` in.
public enum JavaURIResolution {
    /// `new URI(base).resolve(reference).toString()` on ART, or `nil` where that throws: when either text is no URI to
    /// ART's parser, or holds an IPv6 literal, which ``JavaURI`` refuses and Java would read.
    public static func resolve(_ reference: String, against base: String) -> String? {
        guard let baseURI = JavaURI(base), let referenceURI = JavaURI(reference) else {
            return nil
        }
        return baseURI.resolving(referenceURI).text
    }
}

extension JavaURI {
    /// `toString()`: the text it was parsed from, as written, or `defineString()`'s rebuild for one `resolve` built.
    var text: String {
        string ?? definedString
    }

    /// `resolve(URI base, URI child)` with `self` as the base, in ART's form (RFC 2396 §5.2). An opaque URI on either side
    /// gives the reference back as it is, and so does an absolute reference.
    func resolving(_ child: Self) -> Self {
        guard let childPath = child.path, let basePath = path else {
            return child
        }
        var resolved = self
        resolved.string = nil
        // 5.2 (2): a lone fragment is this document, which is itself when the fragment is the same (Java's `equals`, so
        // UTF-16 units, not Swift's canonical equivalence).
        if child.scheme == nil, child.authority == nil, childPath.isEmpty, let fragment = child.fragment, child.query == nil {
            if let own = self.fragment, own.utf16.elementsEqual(fragment.utf16) {
                return self
            }
            resolved.fragment = fragment
            return resolved
        }
        // 5.2 (3): an absolute reference stands alone.
        if child.scheme != nil {
            return child
        }
        resolved.query = child.query
        resolved.fragment = child.fragment
        // 5.2 (4): a reference with its own authority keeps it and its path whole.
        if child.authority != nil {
            resolved.authority = child.authority
            resolved.userInfo = child.userInfo
            resolved.host = child.host
            resolved.port = child.port
            resolved.path = childPath
            return resolved
        }
        if childPath.isEmpty {
            // ART: an empty path keeps the base's, and its query unless the reference has one.
            resolved.query = child.query ?? query
        } else if childPath.hasPrefix("/") {
            // 5.2 (5), with ART's extra step: an absolute path loses its dot segments too.
            resolved.path = JavaURIPath.normalized(childPath)
        } else {
            // 5.2 (6).
            resolved.path = JavaURIPath.resolved(childPath, against: basePath)
        }
        return resolved
    }

    /// `defineString()` for a URI `resolve` built, which is never opaque: an opaque one is handed back with its text.
    private var definedString: String {
        var written = ""
        if let scheme {
            written += scheme + ":"
        }
        if let host {
            written += "//"
            if let userInfo {
                written += userInfo + "@"
            }
            // Java brackets a host holding a `:`, an IPv6 literal, which the parser here refuses; a host is a name or an
            // IPv4 address.
            written += host
            if port != -1 {
                written += ":" + String(port)
            }
        } else if let authority {
            written += "//" + authority
        }
        if let path {
            written += path
        }
        if let query {
            written += "?" + query
        }
        if let fragment {
            written += "#" + fragment
        }
        return written
    }
}

/// ART's path rules for `resolve`: `resolvePath` and `normalize(path, removeLeading: true)`, ported over UTF-16 units
/// as Java walks its `char[]`, `\0` marking where a `/` was split.
internal enum JavaURIPath {
    /// `resolvePath(base, child, absolute)` for a reference with a path: everything in `base` up to its last `/`, then
    /// `child`, normalized. ART takes `absolute` and ignores it, so a base with no `/` at all adds none.
    static func resolved(_ child: String, against base: String) -> String {
        let baseUnits = Array(base.utf16)
        let directory = baseUnits.lastIndex(of: slash).map { baseUnits[...$0] } ?? []
        return normalized(String(decoding: directory, as: UTF16.self) + child)
    }

    /// `normalize(path, true)`: no empty segments, no `.` segment, and no `..` segment, which takes the segment before it
    /// with it or, with none left, goes alone (ART's `removeLeading`). A trailing `/` stays, and a relative path whose
    /// first segment would read as a scheme gets `./` before it (`maybeAddLeadingDot`).
    static func normalized(_ path: String) -> String {
        var units = Array(path.utf16)
        guard needsNormalization(units) else {
            return path
        }
        let starts = split(&units)
        var kept = removeDots(units, starts)
        addLeadingDot(&units, starts, &kept)
        let length = join(&units, starts, kept)
        return String(decoding: units[..<length], as: UTF16.self)
    }

    /// `needsNormalization`: whether `path` has two leading slashes, a redundant slash, or a `.` or `..` segment.
    private static func needsNormalization(_ path: [UInt16]) -> Bool {
        var at = 0
        while at < path.count, path[at] == slash {
            at += 1
        }
        var normal = at <= 1
        while at < path.count {
            if dotSegment(in: path, at: at, separator: slash) != .other {
                normal = false
            }
            while at < path.count {
                at += 1
                if path[at - 1] != slash {
                    continue
                }
                while at < path.count, path[at] == slash {
                    normal = false
                    at += 1
                }
                break
            }
        }
        return !normal
    }

    /// `split`: each segment's start, every `/` in `path` turned into `\0`.
    private static func split(_ path: inout [UInt16]) -> [Int] {
        var segments: [Int] = []
        var at = 0
        while at < path.count, path[at] == slash {
            path[at] = separator
            at += 1
        }
        while at < path.count {
            segments.append(at)
            at += 1
            while at < path.count {
                at += 1
                if path[at - 1] != slash {
                    continue
                }
                path[at - 1] = separator
                while at < path.count, path[at] == slash {
                    path[at] = separator
                    at += 1
                }
                break
            }
        }
        return segments
    }

    /// `removeDots` with `removeLeading`, as whether each segment is kept: a `.` goes, and a `..` goes with the nearest
    /// segment kept before it, or alone. Java keeps a `..` that follows a kept `..`, which never arises here: once a
    /// leading `..` goes, no `..` is ever kept.
    private static func removeDots(_ path: [UInt16], _ starts: [Int]) -> [Bool] {
        var kept = Array(repeating: true, count: starts.count)
        for (index, start) in starts.enumerated() {
            let segment = dotSegment(in: path, at: start, separator: separator)
            if segment != .other {
                kept[index] = false
            }
            if segment == .parent, let previous = kept[..<index].lastIndex(of: true) {
                kept[previous] = false
            }
        }
        return kept
    }

    /// `maybeAddLeadingDot`: a relative path whose first segment went, and whose first kept segment holds a `:`, starts
    /// with a `.` segment, so it can't read as a scheme. A relative path's first segment starts at 0, where the `.` goes.
    private static func addLeadingDot(_ path: inout [UInt16], _ starts: [Int], _ kept: inout [Bool]) {
        guard path[0] != separator, let first = kept.firstIndex(of: true), first > 0 else {
            return
        }
        let start = starts[first]
        let segmentEnd = path[start...].firstIndex(of: separator) ?? path.count
        guard path[start..<segmentEnd].contains(colon) else {
            return
        }
        path[0] = dot
        path[1] = separator
        kept[0] = true
    }

    /// `join`: the kept segments moved down over the gaps, a `/` restored after each that had one, and before the first
    /// for an absolute path. Returns the joined length.
    private static func join(_ path: inout [UInt16], _ starts: [Int], _ kept: [Bool]) -> Int {
        var length = 0
        if path[0] == separator {
            path[0] = slash
            length = 1
        }
        for (start, isKept) in zip(starts, kept) where isKept {
            var at = start
            while at < path.count, path[at] != separator {
                path[length] = path[at]
                length += 1
                at += 1
            }
            if at < path.count {
                path[length] = slash
                length += 1
            }
        }
        return length
    }

    /// What a segment is to `normalize`: `.`, `..`, or any other.
    private enum DotSegment {
        case current, parent, other
    }

    /// The segment at `at`, which ends at `separator` or the end of `path`.
    private static func dotSegment(in path: [UInt16], at: Int, separator: UInt16) -> DotSegment {
        let isEnd = { (index: Int) in index >= path.count || path[index] == separator }
        let next = at + 1
        guard path[at] == dot else {
            return .other
        }
        if isEnd(next) {
            return .current
        }
        return path[next] == dot && isEnd(next + 1) ? .parent : .other
    }

    private static let slash = UInt16(UInt8(ascii: "/"))
    private static let dot = UInt16(UInt8(ascii: "."))
    private static let colon = UInt16(UInt8(ascii: ":"))
    /// Java's `\0`, which no parsed path holds.
    private static let separator: UInt16 = 0
}
