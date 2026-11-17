/// The rules about a spool URL's text (`SpoolUrl.kt` in knit-next, knit-next ADR 2026-09.66cw), shared by the dialer and
/// the relay settings so the two never disagree about which URL a build may use.
///
/// The text is read as UTF-8 bytes, never as characters (ADR 2026-09.jc2x): every separator is ASCII, and a combining
/// mark after a `/` would otherwise hide it from a search by `Character`.
///
/// One departure from the Kotlin: a scheme is matched ignoring ASCII case only. Kotlin's `startsWith(ignoreCase = true)`
/// also folds U+017F, the long s, into `s`, so it reads `wſs://` as `wss://`. Refusing that scheme here costs nothing an
/// honest relay uses.
public enum SpoolURL {
    /// The house relay every phone seeds (knit-next `res/values/spools.xml`).
    public static let house = "wss://public-1.spool.getknit.app/spool/v1"

    private static let secureScheme = Array("wss://".utf8)
    private static let cleartextScheme = Array("ws://".utf8)
    private static let separator = Array("://".utf8)
    /// Printable ASCII, `!` to `~`.
    private static let firstPrintable: UInt8 = 0x21
    private static let lastPrintable: UInt8 = 0x7E
    /// A house relay's former host name and its current one (knit-spool-coordinator ADR 2026-10.ftp9): the same spool,
    /// matched exactly, never as a suffix, since `lab.lax.spool.getknit.app` is another spool.
    private static let renamedHosts = [("lax.spool.getknit.app", "public-1.spool.getknit.app")]

    /// Whether `url`'s scheme is one this build dials: `wss://` always, `ws://` only when `allowCleartext`, which the
    /// caller sets in a debug build alone (C-7.1-2). Both the relay settings and the dialer ask, so a release build is
    /// never pointed at a plaintext relay, however its settings were edited.
    public static func isAcceptable(_ url: String, allowCleartext: Bool) -> Bool {
        guard let scheme = scheme(of: Array(url.utf8)) else {
            return false
        }
        return scheme == secureScheme || allowCleartext
    }

    /// Whether `url` shows a person the host its socket dials: every byte printable ASCII, so no space, control, format
    /// character, bidi override or lookalike letter, and an authority with no user info (`@`) and no backslash, which a
    /// shown `host[:port]` would read differently from the parser that dials. An invite's URL must pass (ADR
    /// 2026-11.adrq).
    public static func isPlain(_ url: String) -> Bool {
        let bytes = Array(url.utf8)
        guard bytes.allSatisfy({ (firstPrintable...lastPrintable).contains($0) }) else {
            return false
        }
        let rest = firstIndex(of: separator, in: bytes).map { bytes[($0 + separator.count)...] } ?? bytes[...]
        let authority = rest.prefix { $0 != ascii("/") && $0 != ascii("?") && $0 != ascii("#") }
        return !authority.contains(ascii("@")) && !authority.contains(ascii("\\"))
    }

    /// The one stored form of `url` (`canonical`): the scheme lowercased and a renamed house relay's host replaced,
    /// nothing else touched, since a path and a token are case-sensitive. Relays are matched by exact text downstream,
    /// so a typed `WSS://relay/spool/v1` and an invite's `wss://relay/spool/v1` would otherwise be two rows for one
    /// host. A URL with neither scheme comes back as it was.
    public static func canonical(_ url: String) -> String {
        let bytes = Array(url.utf8)
        guard let scheme = scheme(of: bytes) else {
            return url
        }
        let rest = bytes[scheme.count...]
        let end = rest.firstIndex { $0 == ascii("/") || $0 == ascii("?") || $0 == ascii("#") } ?? rest.endIndex
        let authority = rest[..<end]
        let at = authority.lastIndex(of: ascii("@"))
        let hostPort = at.map { authority[($0 + 1)...] } ?? authority
        // An IPv6 literal is never a renamed relay.
        guard hostPort.first != ascii("["), let renamed = renamedHost(Array(hostPort.prefix { $0 != ascii(":") })) else {
            return text(scheme + rest)
        }
        let userInfo = at.map { Array(authority[...$0]) } ?? []
        let port = hostPort.drop { $0 != ascii(":") }
        return text(scheme + userInfo + Array(renamed.utf8) + port + rest[end...])
    }

    /// `url` without its `?k=` token (`redact`). Every rendering of a relay goes through this: the token is a private
    /// spool's whole access control, so it never reaches a log line, a screen or a bug report.
    public static func redact(_ url: String) -> String {
        let bytes = Array(url.utf8)
        return text(bytes.prefix { $0 != ascii("?") })
    }

    /// The `host[:port]` a relay's row shows (`host`): no scheme, path or token, or the redacted URL when the shape is
    /// unexpected, so a row is never empty.
    public static func host(_ url: String) -> String {
        let withoutToken = Array(redact(url).utf8)
        guard let start = firstIndex(of: separator, in: withoutToken) else {
            return text(withoutToken)
        }
        let authority = withoutToken[(start + separator.count)...].prefix { $0 != ascii("/") }
        return authority.isEmpty ? text(withoutToken) : text(authority)
    }

    /// Which scheme `url` carries, as its lowercase bytes, or `nil` for any other.
    private static func scheme(of url: [UInt8]) -> [UInt8]? {
        for scheme in [secureScheme, cleartextScheme] where url.count >= scheme.count {
            if zip(url, scheme).allSatisfy({ asciiLowercase($0) == $1 }) {
                return scheme
            }
        }
        return nil
    }

    /// The current name for a former house host, read as Kotlin's `lowercase()` reads it and compared by bytes.
    private static func renamedHost(_ host: [UInt8]) -> String? {
        let lowered = text(host).lowercased()
        return renamedHosts.first { lowered.utf8.elementsEqual($0.0.utf8) }?.1
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else {
            return nil
        }
        return (0...(haystack.count - needle.count)).first { haystack[$0..<($0 + needle.count)].elementsEqual(needle) }
    }

    private static func asciiLowercase(_ byte: UInt8) -> UInt8 {
        (ascii("A")...ascii("Z")).contains(byte) ? byte + (ascii("a") - ascii("A")) : byte
    }

    private static func ascii(_ scalar: Unicode.Scalar) -> UInt8 {
        UInt8(ascii: scalar)
    }

    /// Bytes cut from valid UTF-8 at ASCII boundaries, which are valid UTF-8 again, so decoding substitutes nothing.
    private static func text(_ bytes: some Collection<UInt8>) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: bytes, as: UTF8.self)
    }
}
