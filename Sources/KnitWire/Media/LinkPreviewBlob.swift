/// A link's preview card, as its sender fetched it: the page's title, description and a small picture, kept in an
/// attachment blob typed ``mime`` (`LinkPreviewBlob.kt` in knit-next, ADR 2026-09.n752 there). It rides the photo path
/// unchanged: sealed with the message's key in a DM or a group, in the clear in the Nearby room, and pulled, carried
/// and relayed like any picture. Its readers never contact the site.
///
/// The layout is additive: everything after ``url`` has a default, and ``version`` is required and always written,
/// so a decoder refuses a layout newer than it reads rather than misreading it. A new form mints a new MIME.
///
/// Everything in it is the sender's text, which a reader draws and, for ``url``, opens. ``decode(_:)`` is the only way
/// to read a peer's card: it bounds the bytes, refuses another version, and cleans the card at the boundary
/// (``normalized()``), so no later reader can forget to.
public struct LinkPreviewBlob: Sendable, Equatable, CBORRepresentable {
    /// The layout this build writes.
    public static let currentVersion = 1
    /// The newest layout this build reads.
    public static let maxSupportedVersion = 1
    /// The attachment type that says a blob is a card. It rides `attachmentMime` as `image/webp` does.
    public static let mime = "application/vnd.knit.link-preview"
    /// The longest blob read at all, 256 KiB, checked before the CBOR decoder sees a byte.
    public static let maxBytes = 262_144
    /// The longest picture kept, on both ends: 128 KiB.
    public static let imageMaxBytes = 131_072
    /// The longest title, in UTF-16 units.
    public static let titleMax = 200
    /// The longest description, in UTF-16 units.
    public static let descriptionMax = 400
    /// The longest address, in UTF-16 units.
    public static let maxURLLength = 2048
    /// The picture types a card draws. The sender writes one of these; any other is dropped.
    public static let imageMimes: Set<String> = ["image/jpeg", "image/webp"]

    /// The layout's version, ``currentVersion`` when we write it.
    public var version: Int
    /// The link as it stands in the message's words, normalized by the sender (`LinkPreviewPolicy`), never the page's
    /// own `og:url`: a reader draws the card only beside that link.
    public var url: String
    /// The page's title, or empty for none.
    public var title: String
    /// The page's description.
    public var description: String?
    /// The page's picture, at most 512 pixels on its long side.
    public var image: [UInt8]?
    /// ``image``'s type, one of ``imageMimes``.
    public var imageMime: String?

    /// Makes a card, written in Kotlin's declaration order.
    public init(
        version: Int = currentVersion, url: String, title: String = "", description: String? = nil, image: [UInt8]? = nil,
        imageMime: String? = nil
    ) {
        self.version = version
        self.url = url
        self.title = title
        self.description = description
        self.image = image
        self.imageMime = imageMime
    }

    /// Reads a card's fields as kotlinx would, with none of ``decode(_:)``'s checks. Read a peer's card with that.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "LinkPreviewBlob")
        version = try fields.required("v", .int32)
        url = try fields.required("url", .text)
        title = try fields.optional("title", .text) ?? ""
        description = try fields.nullable("description", .text)
        image = try fields.nullable("image", .bytes)
        imageMime = try fields.nullable("imageMime", .text)
    }

    /// The card as an item, a field at its default left out and `v` always in.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.int("v", version)
        writer.text("url", url)
        writer.text("title", title, default: "")
        writer.text("description", optional: description)
        if let image {
            writer.bytes("image", image)
        }
        writer.text("imageMime", optional: imageMime)
        return writer.cbor
    }

    /// A peer's card, or `nil` when it is empty or over ``maxBytes``, does not decode, is another layout, or its
    /// ``url`` is no plain web address (`decodeOrNull`). Text that is not UTF-8 refuses the card, as every frame here
    /// is refused; Android repairs it instead, which only a hand-made card would show.
    public static func decode(_ bytes: [UInt8]) -> Self? {
        guard !bytes.isEmpty, bytes.count <= maxBytes, let card = try? Self(decoding: bytes),
            (currentVersion...maxSupportedVersion).contains(card.version)
        else {
            return nil
        }
        return card.normalized()
    }

    /// This card with whatever could lie about it taken out (`normalized`): controls and format characters gone from
    /// both texts (the bidi overrides are format characters), runs of whitespace collapsed, both texts cut to their
    /// limits, and a picture kept only when it is a type a card draws and within ``imageMaxBytes``. `nil` only when
    /// ``url`` fails ``isSafeHttpURL(_:)``. The sender cleans the card it writes with this too.
    public func normalized() -> Self? {
        guard Self.isSafeHttpURL(url) else {
            return nil
        }
        let keepsImage =
            image.map { !$0.isEmpty && $0.count <= Self.imageMaxBytes } == true && imageMime.map(Self.imageMimes.contains) == true
        let cleanDescription = description.map { Self.clean($0, limit: Self.descriptionMax) }
        return Self(
            version: version,
            url: url,
            title: Self.clean(title, limit: Self.titleMax),
            description: cleanDescription?.isEmpty == false ? cleanDescription : nil,
            image: keepsImage ? image : nil,
            imageMime: keepsImage ? imageMime : nil)
    }

    /// The host the card is labelled with, from ``url`` and never from anything the page claimed.
    public var host: String { Self.host(of: url) }

    /// The title a card shows: ``title``, or the host when it is blank (`toCard`).
    public var displayTitle: String { TextLimits.isBlank(title) ? host : title }

    /// What the content filter reads: the title and the description, one per line, blanks left out (`moderationText`).
    public var moderationText: String {
        [title, description].compactMap(\.self).filter { !TextLimits.isBlank($0) }.joined(separator: "\n")
    }

    /// Whether `url` is a plain web address a reader may open (`isSafeHttpUrl`): within ``maxURLLength``, no control,
    /// format or whitespace character anywhere, and parsed by `java.net.URI` to an `http` or `https` scheme, a host and
    /// no user-info, since `https://bank.example@evil.example/` reads as the bank at a glance.
    public static func isSafeHttpURL(_ url: String) -> Bool {
        let units = url.utf16
        guard !units.isEmpty, units.count <= maxURLLength, !units.contains(where: isUnsafeURLUnit),
            let parsed = JavaURI(url), let scheme = parsed.scheme?.lowercased(), scheme == "https" || scheme == "http",
            parsed.userInfo == nil, let parsedHost = parsed.host
        else {
            return false
        }
        return !parsedHost.isEmpty
    }

    /// The host `java.net.URI` finds in `url`, lower-cased, a leading `www.` taken off, or empty (`hostOf`).
    public static func host(of url: String) -> String {
        guard let found = JavaURI(url)?.host?.lowercased() else {
            return ""
        }
        return found.hasPrefix(wwwPrefix) ? String(found.dropFirst(wwwPrefix.count)) : found
    }

    /// The text hygiene of a card's title and description, on both ends (`LinkText.clean`): each run of regex `\s`
    /// becomes one space, then every control and format unit goes, then the ends are trimmed, and the rest is cut to
    /// `limit` UTF-16 units without splitting a pair and trimmed again at its end. A format character beyond the BMP stays,
    /// as Kotlin's per-unit filter sees only its surrogates.
    public static func clean(_ raw: String, limit: Int) -> String {
        let collapsed = TextLimits.collapsingWhitespaceRuns(raw)
        var kept = String.UnicodeScalarView()
        for scalar in collapsed.unicodeScalars {
            let isBMP = scalar.value <= UInt32(UInt16.max)
            if isBMP, JavaChar.isISOControl(UInt16(scalar.value)) || JavaChar.isFormat(UInt16(scalar.value)) {
                continue
            }
            kept.append(scalar)
        }
        let trimmed = TextLimits.trimmed(String(kept))
        guard trimmed.utf16.count > limit else {
            return trimmed
        }
        return trimmedEnd(TextLimits.truncated(trimmed, toUTF16: limit))
    }

    /// Kotlin's `trimEnd()`: Kotlin whitespace off the end only.
    private static func trimmedEnd(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let last = scalars.lastIndex(where: { !TextLimits.isKotlinWhitespace($0) }) else {
            return ""
        }
        return String(scalars[...last])
    }

    /// Kotlin's `isUnsafeUrlChar` on one UTF-16 unit.
    private static func isUnsafeURLUnit(_ unit: UInt16) -> Bool {
        JavaChar.isISOControl(unit) || JavaChar.isFormat(unit) || JavaChar.isWhitespace(unit)
    }

    private static let wwwPrefix = "www."
}
