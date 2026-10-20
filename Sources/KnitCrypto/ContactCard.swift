public import KnitWire

/// The contact card (`ContactCard.kt` in knit-next, docs/CONTACT_CARD.md, knit-next ADR 042): a device's identity as a
/// signed text that two people can pass each other out of band, a link in a message or a code, to pin each other's key
/// without a radio in range (ADR 2026-10.tpr5).
///
/// The layout is `Signed { body, sig }`, where `body` is the CBOR of ``ContactCardBody`` and `sig` the identity's raw
/// Ed25519 signature over `"knit/card/v1" ‖ body`. The card certifies itself as a profile does: its node id is the hash
/// of the bundle its keys rebuild, so a card for someone else's id is a hash collision, and the signature stops anyone
/// editing a genuine card's name. The body's bytes are verified exactly as they arrived and never re-encoded
/// (`.agents/rules/interop.md`), so a field Android adds later reads here under `ignoreUnknownKeys`.
///
/// Every text form ``parse(_:)`` takes: the App Link `https://getknit.app/c#<card>`, the scheme link `knit://c/<card>`,
/// either found anywhere in the text, the bare base64url card, and the verify code `knit-id:v1:<nodeId>:<bundle>`
/// (``VerifyPayload``). The text is read as UTF-8, never as characters (ADR 2026-09.jc2x), so a combining mark after a
/// prefix leaves the prefix whole, as Kotlin's `startsWith` and `indexOf` do.
public enum ContactCard {
    /// The card layout's version, `v` (`ContactCard.VERSION`).
    public static let version = 1
    /// The App Link's prefix; the card rides the fragment, which a browser never sends to the server.
    public static let urlPrefix = "https://getknit.app/c#"
    /// The scheme link's prefix.
    public static let schemePrefix = "knit://c/"
    /// The most bytes a card may decode to, refused before its CBOR is read (`MAX_BYTES`).
    public static let maxBytes = 512
    /// The most relay hints a card yields (`MAX_SPOOLS`).
    public static let maxSpools = 3

    /// The signing domain, which keeps a card's signature apart from a frame's or a prekey's (`SIGNING_LABEL`).
    static let signingLabel = Array("knit/card/v1".utf8)
    /// The longest compact text read: base64 of ``maxBytes`` with room for padding (`MAX_COMPACT_CHARS`), 684.
    static let maxCompactCharacters = (maxBytes + base64GroupBytes - 1) / base64GroupBytes * base64GroupSymbols
    /// Base64 writes each 3 bytes as 4 symbols.
    private static let base64GroupBytes = 3
    private static let base64GroupSymbols = 4
    /// The card's `pk`: the two raw public keys, `sigPub ‖ hpkePub`, 64 bytes.
    static let rawKeysByteCount = PublicKeyBundle.keyByteCount + PublicKeyBundle.keyByteCount
    /// The shortest bare run taken for a card (`MIN_BARE_CHARS`): a minimal card is about 240 characters, and a shorter
    /// run is a word or an id, not a card someone mangled.
    static let minBareCharacters = 200
    /// The compact form's alphabet, base64url and its padding (`COMPACT_ALPHABET`).
    private static let compactAlphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=".utf8)

    /// A valid card: the node id, the bundle in its pinned form, the owner's name, the relays and the issue time.
    public struct Card: Sendable, Equatable {
        /// The node id the bundle derives to.
        public let nodeId: NodeId
        /// The bundle's text, standard padded base64, exactly as a profile carries it and the pin keeps it. A card's is
        /// rebuilt from its raw keys; a verify code's is the code's own text, certified only by deriving to the id.
        public let bundle: String
        /// The name, normalized and cut to 32 UTF-16 units, or empty for none. Chosen by whoever sent the card.
        public let name: String
        /// At most ``ContactCard/maxSpools`` relay hints, which this port shows nowhere and never applies.
        public let spools: [String]
        /// When the card was issued, epoch milliseconds on its owner's clock; 0 for a verify code.
        public let issuedAt: Int64

        /// Makes a card.
        public init(nodeId: NodeId, bundle: String, name: String, spools: [String], issuedAt: Int64) {
            self.nodeId = nodeId
            self.bundle = bundle
            self.name = name
            self.spools = spools
            self.issuedAt = issuedAt
        }
    }

    /// Why a text is not a card (`ContactCard.Reason`), in Kotlin's order.
    public enum Reason: Sendable, Equatable, CaseIterable {
        /// Nothing card-shaped in the text at all.
        case notACard
        /// Longer than any card.
        case tooLarge
        /// Not base64url, not the card's CBOR, or a verify code without its fields.
        case malformed
        /// A layout version this build does not read.
        case badVersion
        /// An id that is not 26 characters of base32.
        case badId
        /// Keys that are not two 32-byte keys.
        case badKey
        /// A bundle that does not derive to the id.
        case idMismatch
        /// A signature the card's own key does not verify.
        case badSignature
    }

    /// What ``parse(_:)`` answers.
    public enum Parsed: Sendable, Equatable {
        /// A valid card.
        case card(Card)
        /// Not a card, and why.
        case invalid(Reason)

        /// The card, or `nil`.
        public var card: Card? {
            guard case .card(let card) = self else {
                return nil
            }
            return card
        }
    }

    /// A card in its three text forms (`ContactCards.Minted`).
    public struct Links: Sendable, Equatable {
        /// The bare base64url card.
        public let compact: String
        /// The App Link, `https://getknit.app/c#<compact>`.
        public let url: String
        /// The scheme link, `knit://c/<compact>`.
        public let scheme: String

        /// The forms of `compact`.
        public init(compact: String) {
            self.compact = compact
            url = ContactCard.urlPrefix + compact
            scheme = ContactCard.schemePrefix + compact
        }
    }

    // MARK: Encoding

    /// Our own card, signed by `identity` (`ContactCards.mint` and `ContactCard.encode`, `ContactCard.kt:109-128`), with
    /// `name` normalized as a card's name is and left out when that leaves nothing, and `issuedAt` left out when 0. It
    /// carries no relays: this port has none. `nil` only when signing fails.
    public static func encode(_ identity: IdentityKeys, name: String, issuedAt: Int64) -> Links? {
        encode(bundle: identity.bundle, name: name, spools: [], issuedAt: issuedAt, sign: identity.signature(for:))
    }

    /// A card for `bundle`, signed by `sign`: Kotlin's `encode`, relays and all, for the vectors and the tests.
    static func encode(
        bundle: PublicKeyBundle,
        name: String?,
        spools: [String],
        issuedAt: Int64,
        sign: ([UInt8]) throws(CryptoFailure) -> [UInt8]
    ) -> Links? {
        let body = self.body(bundle: bundle, name: name, spools: spools, issuedAt: issuedAt).encoded
        guard let sig = try? sign(signingLabel + body) else {
            return nil
        }
        return Links(compact: Base64.encode(ContactCardSigned(body: body, sig: sig).encoded, variant: .urlSafeUnpadded))
    }

    /// The body Kotlin's `encode` writes for these fields (`ContactCard.kt:116-124`).
    static func body(bundle: PublicKeyBundle, name: String?, spools: [String], issuedAt: Int64) -> ContactCardBody {
        let clamped = name.map(clampName)
        let hints = Array(spools.prefix(maxSpools))
        return ContactCardBody(
            version: version,
            nodeId: bundle.nodeId.string,
            keys: bundle.signingKey + bundle.agreementKey,
            name: clamped?.isEmpty == false ? clamped : nil,
            spools: hints.isEmpty ? nil : hints,
            issuedAt: issuedAt
        )
    }

    // MARK: Parsing

    /// Reads any accepted text form (`ContactCard.parse`, `ContactCard.kt:140-150`), Kotlin's checks in Kotlin's order.
    /// Never throws and never traps: it is fed straight from a pasted text, a link or a scanned code.
    public static func parse(_ text: String) -> Parsed {
        let trimmedText = TextLimits.trimmed(text)
        let trimmed = Array(trimmedText.utf8)
        if trimmed.starts(with: VerifyPayload.prefix.utf8) {
            return parseLegacy(trimmedText)
        }
        guard let compact = extractCompact(trimmed) else {
            return .invalid(.notACard)
        }
        // A bare run shorter than any card is a word or an id. The run is ASCII, so its bytes are Kotlin's chars.
        if !hasLinkPrefix(trimmed), compact.count < minBareCharacters {
            return .invalid(.notACard)
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
        return decodeSigned(raw)
    }

    /// Whether `text` holds a card at all, cheaply (`looksLikeCard`, `ContactCard.kt:157-162`): a link form anywhere, the
    /// verify code, or a bare run of a card's length. Stricter than ``parse(_:)``'s bare form, so a shared word or a
    /// node id never reads as a card.
    public static func looksLikeCard(_ text: String) -> Bool {
        let trimmed = Array(TextLimits.trimmed(text).utf8)
        if trimmed.starts(with: VerifyPayload.prefix.utf8) {
            return true
        }
        if hasLinkPrefix(trimmed) {
            return extractCompact(trimmed) != nil
        }
        // Kotlin counts the trimmed text's UTF-16 units; a run that passes the alphabet is ASCII, where they agree.
        return trimmed.count >= minBareCharacters && extractCompact(trimmed) != nil
    }

    /// The verify code read as a card (`parseLegacy`, `ContactCard.kt:200-205`): no name, no relays, no issue time, and
    /// no signature beyond the code's own certification, the id the hash of the bundle's text. The bundle's text is
    /// kept as the code wrote it, as Kotlin keeps it.
    private static func parseLegacy(_ trimmed: String) -> Parsed {
        guard let code = VerifyPayload.parse(trimmed) else {
            return .invalid(.malformed)
        }
        guard isNodeId(Array(code.nodeId.utf8)) else {
            return .invalid(.badId)
        }
        guard let nodeId = code.certifiedNodeId else {
            return .invalid(.idMismatch)
        }
        return .card(Card(nodeId: nodeId, bundle: code.bundle, name: "", spools: [], issuedAt: 0))
    }

    /// The signed card's checks (`decodeSigned`, `ContactCard.kt:167-194`).
    private static func decodeSigned(_ raw: [UInt8]) -> Parsed {
        guard let signed = try? ContactCardSigned(decoding: raw), let body = try? ContactCardBody(decoding: signed.body) else {
            return .invalid(.malformed)
        }
        guard body.version == version else {
            return .invalid(.badVersion)
        }
        guard isNodeId(Array(body.nodeId.utf8)) else {
            return .invalid(.badId)
        }
        let keyBytes = PublicKeyBundle.keyByteCount
        guard body.keys.count == rawKeysByteCount,
            let bundle = PublicKeyBundle(signingKey: Array(body.keys[..<keyBytes]), agreementKey: Array(body.keys[keyBytes...]))
        else {
            return .invalid(.badKey)
        }
        guard bundle.nodeId.string.utf8.elementsEqual(body.nodeId.utf8) else {
            return .invalid(.idMismatch)
        }
        // Over the body's bytes as they arrived, never re-encoded.
        guard bundle.isValidSignature(signed.sig, for: signingLabel + signed.body) else {
            return .invalid(.badSignature)
        }
        return .card(
            Card(
                nodeId: bundle.nodeId,
                bundle: bundle.encoded,
                name: body.name.map(clampName) ?? "",
                spools: Array((body.spools ?? []).prefix(maxSpools)),
                issuedAt: body.issuedAt
            )
        )
    }

    /// The compact card in `text` (`extractCompact`, `ContactCard.kt:211-220`): the alphabet run after the first link
    /// prefix found, the App Link's looked for before the scheme's, or the whole text when it is one run. A prefix found
    /// with nothing after it answers `nil`, without looking for the other. Searching bytes finds what Kotlin's `indexOf`
    /// finds: both prefixes are ASCII, and UTF-8 never puts an ASCII byte inside another character.
    private static func extractCompact(_ text: [UInt8]) -> [UInt8]? {
        for prefix in [urlPrefix, schemePrefix] {
            if let at = firstIndex(of: Array(prefix.utf8), in: text) {
                let run = Array(text[(at + prefix.utf8.count)...].prefix(while: compactAlphabet.contains))
                return run.isEmpty ? nil : run
            }
        }
        return !text.isEmpty && text.allSatisfy(compactAlphabet.contains) ? text : nil
    }

    private static func hasLinkPrefix(_ text: [UInt8]) -> Bool {
        firstIndex(of: Array(urlPrefix.utf8), in: text) != nil || firstIndex(of: Array(schemePrefix.utf8), in: text) != nil
    }

    /// The first offset where `needle`'s bytes occur in `text`.
    private static func firstIndex(of needle: [UInt8], in text: [UInt8]) -> Int? {
        guard text.count >= needle.count else {
            return nil
        }
        return (0...(text.count - needle.count)).first { text[$0..<($0 + needle.count)].elementsEqual(needle) }
    }

    /// `java.util.Base64.getUrlDecoder()`: base64url, padding optional but exact when present, which is the standard
    /// decoder's rule (``Base64/decode(_:variant:)``) once `-` and `_` read as `+` and `/`. Neither of those is in the
    /// compact alphabet, so the swap is exact.
    private static func decodeURLSafe(_ compact: [UInt8]) -> [UInt8]? {
        let standard = compact.map { byte -> Unicode.Scalar in
            switch byte {
            case UInt8(ascii: "-"):
                "+"
            case UInt8(ascii: "_"):
                "/"
            default:
                Unicode.Scalar(byte)
            }
        }
        return Base64.decode(String(String.UnicodeScalarView(standard)))
    }

    /// Kotlin's `isNodeId` (`ContactCard.kt:222`): 26 characters of the base32 alphabet, canonical or not.
    private static func isNodeId(_ text: [UInt8]) -> Bool {
        text.count == NodeId.length && text.allSatisfy(NodeId.alphabet.contains)
    }

    /// A card's name as Kotlin's `clampName` leaves it (`ContactCard.kt:224`): `normalizeSingleLine`, then cut to 32 UTF-16
    /// units without splitting a surrogate pair. This follows knit-next's `main` past this port's pin (`5f521cb9`), where
    /// `clampToUtf16` replaced a `take(32)` that could split one; ``TextLimits/truncated(_:toUTF16:)`` already cut so.
    static func clampName(_ name: String) -> String {
        TextLimits.truncated(TextLimits.normalizeSingleLine(name), toUTF16: TextLimits.displayName)
    }
}
