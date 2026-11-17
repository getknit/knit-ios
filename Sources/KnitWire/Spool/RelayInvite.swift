/// The relay invite (`RelayInvite.kt` in knit-next, `docs/RELAY_INVITE.md`, knit-next ADR 2026-09.tmbq): one relay as a
/// link, `https://getknit.app/r#<invite>` or `knit://r/<invite>`, found anywhere in a text.
///
/// The invite is the base64url CBOR of `Body { v: 1, u, c?, n?, i?, k? }`, unsigned: the URL is the capability, its
/// `?k=` token included, and a relay has no key to sign as. This build reads `u` alone (ADR 2026-11.adrq). `c` and `n`
/// are a commons room and `i` and `k` a Knit Anywhere issuer and key, none of which it uses, yet it refuses an invite
/// whose `c` has the wrong length or whose `i` and `k` are malformed or half a pair, as every Android build does, so the
/// two never disagree about which links are invites.
///
/// The text is read as UTF-8, never as characters (ADR 2026-09.jc2x), as ``ContactCard`` reads its links.
public enum RelayInvite {
    /// The layout's version, `v` (`VERSION`).
    public static let version = 1
    /// The App Link's prefix. The invite rides the fragment, which a browser never sends to the server.
    public static let urlPrefix = "https://getknit.app/r#"
    /// The scheme link's prefix.
    public static let schemePrefix = "knit://r/"
    /// The most bytes an invite may decode to, refused before its CBOR is read (`MAX_BYTES`).
    public static let maxBytes = 512
    /// The longest relay URL an invite may carry, in UTF-16 units (`MAX_URL_CHARS`).
    public static let maxURLCharacters = 256
    /// A commons secret's length (`ScopeCrypto.COMMONS_SECRET_BYTES`).
    static let secretByteCount = 32
    /// The longest issuer origin, in UTF-16 units (`IssuerOrigin.MAX_CHARS`).
    static let maxIssuerCharacters = 128
    /// The longest compact text read: base64 of ``maxBytes`` with room for padding (`MAX_COMPACT_CHARS`), 684.
    static let maxCompactCharacters = (maxBytes + base64GroupBytes - 1) / base64GroupBytes * base64GroupSymbols
    /// Base64 writes each 3 bytes as 4 symbols.
    private static let base64GroupBytes = 3
    private static let base64GroupSymbols = 4
    /// A customer key's symbols after `kak1_`: base64url of 32 bytes, unpadded.
    private static let keySymbols = 43
    /// The most digits a port takes, and the highest port.
    private static let portDigits = 1...5
    private static let maxPort = 65_535
    /// The first byte past ASCII.
    private static let firstNonASCII: UInt8 = 0x80
    /// The compact form's alphabet, base64url and its padding (`COMPACT_ALPHABET`).
    private static let compactAlphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=".utf8)

    /// A well-formed invite: the relay's URL, exactly as it is stored, token included. Its description names the host
    /// alone, so a log line that mentions an invite never carries the token.
    public struct Invite: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        /// The spool URL, `u`.
        public let url: String

        /// Makes an invite.
        public init(url: String) {
            self.url = url
        }

        /// `Invite(host=…)`, never the URL.
        public var description: String { "Invite(host=\(SpoolURL.host(url)))" }

        /// The same as ``description``.
        public var debugDescription: String { description }

        /// No children, so `dump`, a debugger's `po` and a reflecting logger see the host alone, never the token.
        public var customMirror: Mirror { Mirror(self, children: KeyValuePairs<String, Any>()) }
    }

    /// Why a text is not an invite (`RelayInvite.Reason`).
    public enum Reason: Equatable, Sendable {
        /// Nothing invite-shaped in the text.
        case notAnInvite
        /// The link or its body is past ``maxBytes``.
        case tooLarge
        /// Not base64url, or not the body's CBOR.
        case malformed
        /// A layout version this build does not read.
        case badVersion
        /// A URL this build may not dial, or not one anybody typed.
        case badURL
        /// A commons secret of the wrong length.
        case badSecret
        /// A key with no issuer, or an issuer that is not an origin.
        case badIssuer
        /// An issuer with no key, or a key that is not a customer key.
        case badKey
    }

    /// What ``parse(_:allowCleartext:)`` finds.
    public enum Parsed: Equatable, Sendable {
        /// An invite.
        case invite(Invite)
        /// Not one, and why.
        case invalid(Reason)
    }

    /// The invite's compact form for `url` (`mint`): its body with `v` and `u` alone, base64url without padding. This
    /// build never writes a room, an issuer or a key.
    public static func mint(url: String) -> String {
        var writer = CBORFieldWriter()
        writer.int("v", version)
        writer.text("u", TextLimits.trimmed(url))
        return Base64.encode(writer.cbor.encoded, variant: .urlSafeUnpadded)
    }

    /// Reads either link form found anywhere in `text`, Kotlin's checks in Kotlin's order (`parse`). Never throws and
    /// never traps: it is fed from a pasted text or an opened link. `allowCleartext` is the build's `ws://` rule, which
    /// the caller sets in a debug build alone, as for ``SpoolURL/isAcceptable(_:allowCleartext:)``.
    public static func parse(_ text: String, allowCleartext: Bool) -> Parsed {
        guard let compact = extractCompact(Array(TextLimits.trimmed(text).utf8)) else {
            return .invalid(.notAnInvite)
        }
        guard compact.count <= maxCompactCharacters else {
            return .invalid(.tooLarge)
        }
        guard let raw = decodeURLSafe(compact) else {
            return .invalid(.malformed)
        }
        guard raw.count <= maxBytes else {
            return .invalid(.tooLarge)
        }
        return decodeBody(raw, allowCleartext: allowCleartext)
    }

    /// Whether `text` holds an invite link at all, cheaply (`looksLikeInvite`): a link prefix with something after it.
    /// There is no bare form, so a base64-looking paragraph is never taken for one.
    public static func looksLikeInvite(_ text: String) -> Bool {
        extractCompact(Array(TextLimits.trimmed(text).utf8)) != nil
    }

    /// The body's checks (`decodeBody`).
    private static func decodeBody(_ raw: [UInt8], allowCleartext: Bool) -> Parsed {
        guard let item = try? CBOR.decode(raw), let body = try? InviteBody(cbor: item) else {
            return .invalid(.malformed)
        }
        guard body.version == version else {
            return .invalid(.badVersion)
        }
        guard isUsableURL(body.url, allowCleartext: allowCleartext) else {
            return .invalid(.badURL)
        }
        if let secret = body.secret, secret.count != secretByteCount {
            return .invalid(.badSecret)
        }
        // Both or neither, each refused as a whole invite: a link that half-carries a key was built wrong.
        if body.key != nil, !(body.issuer.map { isAcceptableIssuer($0, allowCleartext: allowCleartext) } ?? false) {
            return .invalid(.badIssuer)
        }
        if body.issuer != nil, !(body.key.map(isWellFormedKey) ?? false) {
            return .invalid(.badKey)
        }
        return .invite(Invite(url: body.url))
    }

    /// A URL the dialer would take (`isUsableUrl`): not blank, at most ``maxURLCharacters`` UTF-16 units, no whitespace
    /// or control unit as Kotlin's `Char` reads them, and a scheme ``SpoolURL`` accepts. A link is attacker-typed, so this
    /// build also asks for a plain URL (``SpoolURL/isPlain(_:)``), whose shown host is the host it dials.
    private static func isUsableURL(_ url: String, allowCleartext: Bool) -> Bool {
        !url.isEmpty
            && url.utf16.count <= maxURLCharacters
            && !url.utf16.contains { JavaChar.isWhitespace($0) || JavaChar.isISOControl($0) }
            && SpoolURL.isPlain(url)
            && SpoolURL.isAcceptable(url, allowCleartext: allowCleartext)
    }

    /// `IssuerOrigin.isAcceptable`: `^(https?)://(host|\[ipv6])(:port)?$` over ASCII, the host DNS-shaped labels of
    /// `[a-z0-9]` with inner hyphens, the port 1 to 65535 without a leading zero, and `http` only when `allowCleartext`.
    /// Checked by hand over bytes, since every character it admits is ASCII.
    private static func isAcceptableIssuer(_ origin: String, allowCleartext: Bool) -> Bool {
        let bytes = Array(origin.utf8)
        guard origin.utf16.count <= maxIssuerCharacters, bytes.allSatisfy({ $0 < firstNonASCII }) else {
            return false
        }
        let rest: ArraySlice<UInt8>
        if bytes.starts(with: "https://".utf8) {
            rest = bytes.dropFirst("https://".utf8.count)
        } else if allowCleartext, bytes.starts(with: "http://".utf8) {
            rest = bytes.dropFirst("http://".utf8.count)
        } else {
            return false
        }
        let hostEnd: ArraySlice<UInt8>.Index
        if rest.first == UInt8(ascii: "[") {
            guard let close = rest.firstIndex(of: UInt8(ascii: "]")), close > rest.startIndex + 1,
                rest[(rest.startIndex + 1)..<close].allSatisfy(isIPv6Byte)
            else {
                return false
            }
            hostEnd = close + 1
        } else {
            hostEnd = rest.firstIndex(of: UInt8(ascii: ":")) ?? rest.endIndex
            guard isDNSName(rest[..<hostEnd]) else {
                return false
            }
        }
        let port = rest[hostEnd...]
        return port.isEmpty || isPort(port)
    }

    /// `CustomerKey.isWellFormed`: `^kak1_[A-Za-z0-9_-]{43}$`.
    private static func isWellFormedKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        let prefix = "kak1_".utf8
        let base64URL = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
        return bytes.count == prefix.count + keySymbols && bytes.starts(with: prefix)
            && bytes.dropFirst(prefix.count).allSatisfy(base64URL.contains)
    }

    /// Labels of `[a-z0-9]`, each starting and ending with one, with hyphens inside, joined by dots.
    private static func isDNSName(_ host: ArraySlice<UInt8>) -> Bool {
        let labels = host.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        return !host.isEmpty
            && labels.allSatisfy { label in
                guard let first = label.first, let last = label.last, isLowerAlphanumeric(first), isLowerAlphanumeric(last) else {
                    return false
                }
                return label.allSatisfy { isLowerAlphanumeric($0) || $0 == UInt8(ascii: "-") }
            }
    }

    /// `:` and `[1-9][0-9]{0,4}`, at most 65535.
    private static func isPort(_ port: ArraySlice<UInt8>) -> Bool {
        let digits = port.dropFirst()
        guard port.first == UInt8(ascii: ":"), portDigits.contains(digits.count), digits.first != UInt8(ascii: "0"),
            digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
            let value = Int(String(ascii: Array(digits)))
        else {
            return false
        }
        return value <= maxPort
    }

    private static func isLowerAlphanumeric(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    /// `[0-9a-f:.]`.
    private static func isIPv6Byte(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            || byte == UInt8(ascii: ":") || byte == UInt8(ascii: ".")
    }

    /// The compact invite after the first link prefix found (`extractCompact`), the App Link's looked for before the
    /// scheme's; `nil` when neither is there or nothing follows. Searching bytes finds what Kotlin's `indexOf` finds: the
    /// prefixes are ASCII, and UTF-8 never puts an ASCII byte inside another character.
    private static func extractCompact(_ text: [UInt8]) -> [UInt8]? {
        for prefix in [urlPrefix, schemePrefix] {
            let needle = Array(prefix.utf8)
            guard text.count >= needle.count,
                let at = (0...(text.count - needle.count)).first(where: { text[$0..<($0 + needle.count)].elementsEqual(needle) })
            else {
                continue
            }
            let run = Array(text[(at + needle.count)...].prefix(while: compactAlphabet.contains))
            return run.isEmpty ? nil : run
        }
        return nil
    }

    /// `java.util.Base64.getUrlDecoder()`: base64url, padding optional but exact when present, which is
    /// ``Base64/decode(_:variant:)``'s standard rule once `-` and `_` read as `+` and `/` (as ``ContactCard`` decodes).
    private static func decodeURLSafe(_ compact: [UInt8]) -> [UInt8]? {
        let standard = compact.map { byte -> UInt8 in
            switch byte {
            case UInt8(ascii: "-"):
                UInt8(ascii: "+")
            case UInt8(ascii: "_"):
                UInt8(ascii: "/")
            default:
                byte
            }
        }
        return Base64.decode(String(ascii: standard))
    }
}

/// The invite's body (the private `RelayInvite.Body`): `v` and `u` required, the rest nullable, `c` a byte string. Read
/// only: ``RelayInvite/mint(url:)`` writes the two fields it ever sends.
private struct InviteBody: CBORShape {
    var version: Int
    var url: String
    var secret: [UInt8]?
    var issuer: String?
    var key: String?

    init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "RelayInvite.Body")
        version = try fields.required("v", .int32)
        url = try fields.required("u", .text)
        secret = try fields.nullable("c", .bytes)
        _ = try fields.nullable("n", .text)
        issuer = try fields.nullable("i", .text)
        key = try fields.nullable("k", .text)
    }
}
