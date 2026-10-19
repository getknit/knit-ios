/// Protocol capability bits (`Protocol.CAP_*` in knit-next).
///
/// The signed copy in `ProfileContent.capabilities` is the one that gates behaviour, and only at send time.
/// The advert's low byte and the HELLO's hex copy are routing hints. A bit is a promise: advertise only what
/// this build implements (`.agents/rules/interop.md`).
public struct Capabilities: OptionSet, Hashable, Sendable, ExpressibleByIntegerLiteral {
    /// End-to-end encrypted DMs. Diagnostic only.
    public static let endToEnd: Self = 0x001
    /// Group chats. Diagnostic only.
    public static let groups: Self = 0x002
    /// Reactions. Diagnostic only.
    public static let reactions: Self = 0x004
    /// Store-and-forward custody. Diagnostic only.
    public static let storeForward: Self = 0x008
    /// The v2 epoch ratchet. With a published prekey, it makes Android seal DMs as v2 toward us.
    public static let ratchet: Self = 0x010
    /// Compact fast-plane encoding (Wi-Fi Aware only).
    public static let fastCompact: Self = 0x020
    /// Inline acknowledgements on a sealed DM.
    public static let inlineAck: Self = 0x040
    /// Fast-plane frame transcoding (Wi-Fi Aware, LoRa and the side channel only).
    public static let frameTranscode: Self = 0x080
    /// The v3 compact DM ratchet; requires ``ratchet``.
    public static let cryptoV3: Self = 0x100
    /// File attachments.
    public static let files: Self = 0x200
    /// Link-preview cards.
    public static let linkPreview: Self = 0x400
    /// Wi-Fi Direct file transfer.
    public static let directTransfer: Self = 0x800
    /// This node serves the GATT doorbell; ring it after frames. Read from the HELLO only, and sent only there, by a
    /// radio that serves one (`Radio.servesDoorbell`): it is above the advert's 8 bits, and never in the profile.
    public static let doorbell: Self = 0x1000
    /// This node answers a `blobhave` query with a `blobhas` (`Protocol.CAP_BLOB_HAVE`, knit-next ADR 2026-10.6e5t). An
    /// asker queries only a neighbour whose link carries it, since a build without it refuses the unsigned frame and the
    /// asker would wait out an answer that never comes. Read from the HELLO only, never from a pinned profile, and sent
    /// only there: every build answers, so every HELLO claims it, and it is above the advert's 8 bits.
    public static let blobHave: Self = 0x2000

    /// What this build advertises: end-to-end DMs, groups, reactions and store-and-forward, with the ratchet's three bits,
    /// ``ratchet``, ``inlineAck`` and ``cryptoV3`` (`0x15F`, ADR 2026-09.n393, ADR 2026-10.ehe6, ADR 2026-10.5sk9). Android
    /// reads the reactions bit for diagnostics only, and the ratchet's from our signed profile alone
    /// (`CryptoScheme.kt:11-13`), which carries them only beside our prekey with the ratchet's switch on
    /// (`MeshConfiguration.capabilities`); the HELLO and the advert carry this set whatever the switch says, as hints
    /// nothing seals by. Never ``fastCompact`` or ``frameTranscode``, which are fast-plane encodings this port has no
    /// plane for, and never ``doorbell`` or ``blobHave``: those are the link's to claim, in the HELLO alone.
    public static let local: Self = [.endToEnd, .groups, .reactions, .storeForward, .ratchet, .inlineAck, .cryptoV3]

    /// The ratchet's bits: what our signed profile drops with the switch off or no prekey kept, so it reads as it did
    /// before the ratchet (`0xF`), since `CAP_RATCHET` promises a published prekey (`MeshManager.kt:2963-2979`).
    public static let ratchetSuite: Self = [.ratchet, .inlineAck, .cryptoV3]

    /// The bit field, a Kotlin `Long`.
    public let rawValue: Int64

    /// Wraps a bit field.
    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    /// Wraps a bit field written as a literal.
    public init(integerLiteral value: Int64) {
        rawValue = value
    }

    /// The bits in lowercase hexadecimal with no leading zeros, as the HELLO carries them
    /// (Kotlin's `Long.toString(16)`): `fff` for Android, `15f` for us.
    public var hex: String { String(rawValue, radix: Self.hexRadix) }

    private static let hexRadix = 16
}
