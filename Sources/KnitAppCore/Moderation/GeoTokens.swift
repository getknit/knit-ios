import Foundation

/// The positions Knit for Android shares in a message's words, as `geo:` tokens (`GeoUri.kt`), which come out before the
/// content filter reads them (`MeshManager.isTextFlagged`, ADR 2026-09.tss4 there). The word list reads digits as
/// letters, so a latitude such as `37.9455` can spell a listed word, and the model was never shown a position. This
/// build draws no map, so the token is only ever taken out, never read.
internal enum GeoTokens {
    /// One position, as `GeoUri.GRAMMAR` has it: latitude, longitude, and an altitude, a crs, an uncertainty and a
    /// query that may follow. Digits are ASCII, as Java's `\d` is. A `Regex` is not `Sendable`, so each read that meets
    /// `geo:` builds its own, typed by its captures: the match, the latitude, the longitude and the uncertainty.
    private static var grammar: Regex<(Substring, Substring, Substring, Substring?)> { // swiftlint:disable:this large_tuple
        #/
        geo: (-?\d{1,2}(?:\.\d{1,12})?) , (-?\d{1,3}(?:\.\d{1,12})?)
        (?:,-?\d+(?:\.\d+)?)? (?:;crs=wgs84)? (?:;u=(\d+(?:\.\d+)?))? (?:\?\S*)?
        /#
        .ignoresCase()
        .asciiOnlyDigits()
    }
    /// Longest token read (`GeoUri.MAX_TOKEN_LENGTH`).
    private static let longest = 96
    /// How far a latitude and a longitude may reach, in degrees.
    private static let latitudes = 90.0
    private static let longitudes = 180.0
    /// Punctuation that opens on a token, and punctuation that trails one in prose: neither is part of it.
    private static let leading: Set<Character> = ["(", "\"", "'", "“", "‘", "«", "[", "{"]
    private static let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", "\"", "'", "”", "’", "»", ")", "]", "}"]

    /// `body` with every position taken out (`GeoUri.strip`): a line that held only positions goes, runs of spaces or
    /// tabs left behind become one, and the ends are trimmed.
    static func strip(_ body: String) -> String {
        guard body.range(of: "geo:", options: .caseInsensitive) != nil else {
            return body
        }
        let lines = body.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
        let kept = lines.compactMap { line -> String? in
            let positions = scan(line)
            guard !positions.isEmpty else {
                return String(line)
            }
            var rest = ""
            var cursor = line.startIndex
            for range in positions {
                rest += line[cursor..<range.lowerBound]
                cursor = range.upperBound
            }
            rest += line[cursor...]
            let squeezed = rest.replacing(#/[ \t]{2,}/#, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return squeezed.isEmpty ? nil : squeezed
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where `line`'s whitespace-bounded tokens are positions, once the punctuation around each is set aside.
    private static func scan(_ line: Substring) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var index = line.startIndex
        while index < line.endIndex {
            guard !line[index].isWhitespace else {
                index = line.index(after: index)
                continue
            }
            let end = line[index...].firstIndex(where: \.isWhitespace) ?? line.endIndex
            var start = index
            while start < end, leading.contains(line[start]) {
                start = line.index(after: start)
            }
            var stop = end
            while stop > start, trailing.contains(line[line.index(before: stop)]) {
                stop = line.index(before: stop)
            }
            if isPosition(line[start..<stop]) {
                found.append(start..<stop)
            }
            index = end
        }
        return found
    }

    /// Whether `token` is one position in range (`GeoUri.parse`).
    private static func isPosition(_ token: Substring) -> Bool {
        guard token.count <= longest, let match = try? grammar.wholeMatch(in: token),
            let latitude = Double(match.output.1), let longitude = Double(match.output.2)
        else {
            return false
        }
        let metres = match.output.3.map { Double($0)?.isFinite == true } ?? true
        return abs(latitude) <= latitudes && abs(longitude) <= longitudes && metres
    }
}
