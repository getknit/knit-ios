import KnitCrypto
import KnitWire

/// Which link in a message gets a card, and the one form of a link that the card's own address is compared in
/// (`LinkPreviewPolicy.kt` in knit-next, ADR 2026-11.hcvg).
///
/// The rules are narrower than "a web address": the sender's fetch is a socket toward an address somebody typed, so
/// anything that could point it at the wrong place is refused before a resolver is asked. That covers a port other
/// than 443, an IP literal or a single-label name, a local or `.onion` name, and user-info that spoofs a host. A Knit
/// contact link is a card of its own, not a page.
///
/// ``sameURL(_:_:)`` is also the reader's check that a card describes a link the message's words hold, so a sender cannot
/// attach a bank's card to another page's link.
///
/// One limit, where Android goes further: a host outside ASCII is refused here, where Android turns it into punycode
/// (`IDN.toASCII`). Linux has no IDNA, and the rule must read the same on both, so a link to `bücher.example` gets no
/// card on this phone, drawn or fetched.
public enum LinkPreviewPolicy {
    /// How many links at the head of a message are tried before it gets no card (`CANDIDATES`).
    public static let candidates = 3

    /// The first of the first ``candidates`` links in `body` that ``normalize(_:)`` keeps, normalized, or `nil`
    /// (`firstEligible`).
    public static func firstEligible(_ body: String) -> String? {
        LinkText.links(in: body).prefix(candidates).lazy.compactMap { normalize($0.url) }.first
    }

    /// `url` in the one form the fetch, the memo and a reader's check all agree on, or `nil` when it is no link this
    /// phone fetches (`normalize`): `https`, a typed `http` upgraded; the default port only; a public host of two labels
    /// or more, lower-cased; the fragment dropped, and the path and query kept as written, `/` when there is none.
    public static func normalize(_ url: String) -> String? {
        let trimmed = TextLimits.trimmed(url)
        guard !trimmed.isEmpty, trimmed.utf16.count <= LinkPreviewBlob.maxURLLength, !ContactCard.looksLikeCard(trimmed),
            let (authority, rest) = parts(of: trimmed), let host = acceptableHost(authority)
        else {
            return nil
        }
        let path = rest.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return "https://" + host + (path.isEmpty ? "/" : path)
    }

    /// Whether `left` and `right` are one link once normalized; `false` when either is no link this phone fetches
    /// (`sameUrl`).
    public static func sameURL(_ left: String, _ right: String) -> Bool {
        guard let normalized = normalize(left) else {
            return false
        }
        return normalized == normalize(right)
    }

    /// Kotlin's `(?i)^(https?)://([^/?#\s]+)(\S*)$` matched whole, `\s` as ART reads it (ADR 2026-10.7uyt): the authority,
    /// up to the first `/`, `?` or `#`, and everything after it, or `nil` when `text` is no `http` or `https` address
    /// with an authority, or holds whitespace anywhere. The scheme's case is ASCII's alone, as `(?i)` without
    /// `UNICODE_CASE` reads it.
    private static func parts(of text: String) -> (authority: String, rest: String)? {
        let scalars = Array(text.unicodeScalars)
        let schemes = ["https://", "http://"].map { Array($0.unicodeScalars) }
        guard let scheme = schemes.first(where: { startsCaselessly(scalars, with: $0) }),
            !scalars.contains(where: TextLimits.isJavaRegexWhitespace)
        else {
            return nil
        }
        let afterScheme = scalars[scheme.count...]
        let end = afterScheme.firstIndex { authorityEnds.contains($0) } ?? scalars.endIndex
        guard end > afterScheme.startIndex else {
            return nil
        }
        var authority = String.UnicodeScalarView()
        authority.append(contentsOf: scalars[afterScheme.startIndex..<end])
        var rest = String.UnicodeScalarView()
        rest.append(contentsOf: scalars[end...])
        return (String(authority), String(rest))
    }

    /// Whether `scalars` start with `prefix`, ASCII letters in either case.
    private static func startsCaselessly(_ scalars: [Unicode.Scalar], with prefix: [Unicode.Scalar]) -> Bool {
        scalars.count >= prefix.count && zip(scalars, prefix).allSatisfy { lowered($0) == $1 }
    }

    /// `scalar` with an ASCII capital lowered, anything else as it is.
    private static func lowered(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        ("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + asciiCaseOffset) ?? scalar : scalar
    }

    /// The host in `authority` when this phone fetches from it, lower-cased, or `nil` (`acceptableHost`): no user-info, no
    /// bracketed literal, a port only when it is 443, two labels or more of letters, digits and dashes, not all digits and
    /// dots, and none of the names a local or onion network answers.
    private static func acceptableHost(_ authority: String) -> String? {
        guard !authority.contains("@"), !authority.hasPrefix("[") else {
            return nil
        }
        let split = authority.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let port = split.count > 1 ? String(split[1]) : ""
        guard port.isEmpty || port == httpsPort, let hostPart = split.first, hostPart.unicodeScalars.allSatisfy(\.isASCII) else {
            return nil
        }
        let host = String(hostPart).lowercased()
        guard isHostname(host), !host.allSatisfy({ $0 == "." || ("0"..."9").contains($0) }),
            !localSuffixes.contains(where: { host == $0.dropFirst() || host.hasSuffix($0) })
        else {
            return nil
        }
        return host
    }

    /// Kotlin's `^[a-z0-9-]{1,63}(\.[a-z0-9-]{1,63})+$`.
    private static func isHostname(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= minLabels
            && labels.allSatisfy { label in
                (1...maxLabel).contains(label.utf8.count) && label.unicodeScalars.allSatisfy(isHostCharacter)
            }
    }

    private static func isHostCharacter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-"
    }

    /// Where an authority ends: Kotlin's `[^/?#\s]`, whose whitespace ``parts(of:)`` refuses whole.
    private static let authorityEnds: Set<Unicode.Scalar> = ["/", "?", "#"]
    private static let httpsPort = "443"
    /// The fewest labels a host has: a single label is a name on the local network.
    private static let minLabels = 2
    /// The longest DNS label.
    private static let maxLabel = 63
    /// From an ASCII capital to its small letter.
    private static let asciiCaseOffset: UInt32 = 0x20
    /// Names that resolve on the local network, not the Internet, and `.onion`, whose lookup would leak (`LOCAL_SUFFIXES`).
    private static let localSuffixes = [".local", ".localhost", ".internal", ".home.arpa", ".arpa", ".onion", ".lan", ".home"]
}
