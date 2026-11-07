/// Protocol capability bits (`Protocol.CAP_*` in knit-next).
///
/// The signed copy in `ProfileContent.capabilities` is the one that gates behaviour: at send time, and for ``linkProof``
/// at a link's admission. The advert's low byte and the HELLO's hex copy are routing hints, but for ``linkProof``, whose
/// HELLO copy decides whether a link runs the proof that then covers both HELLOs. A bit is a promise: advertise only what
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
    /// This node proves on every link the node id its HELLO claims, by signing both HELLOs with its identity key
    /// (`Protocol.CAP_LINK_PROOF`, knit-next #232, knit-ios #25), and refuses an unsigned claim to the id of a peer it knows
    /// can prove itself. Read from two places: from a peer's signed profile, which makes that peer one a link must prove,
    /// since a profile carries the peer's own signature and no one else can strip the bit; and from a HELLO, which decides
    /// whether this link runs the exchange. Above the advert's 8 bits, so never there. `0x10000` (`LORA_DIRECT`) and
    /// `0x20000` (`INET_LINK`) are Android's LoRa and internet links, which this port has neither of, unnamed here.
    public static let linkProof: Self = 0x40000
    /// "I read tags" (`Protocol.CAP_BLIND_ADVERT`, `Protocol.kt:218-227` at knit-next `cad69c77b`; knit-next ADR
    /// 2026-11.xp6d; ADR 2026-11.sv5t): this node resolves a blinded advert's rotating tag, dials one, and reads a
    /// HELLO's `t` and `a`. It says nothing of writing tags. Android reads it from a peer's HELLO or pinned profile to send
    /// that peer `TAG_NEXT` (link record tag 9) and its presence keys (ctl 11), and while it blinds refuses a dialer whose
    /// HELLO lacks it. Not in ``local`` until tag 9 and ctl 11 both read here: Android does not resend a ctl 11 a peer
    /// dropped until its next generation, root or restart. Above the advert's 8 bits, so never there.
    public static let blindAdvert: Self = 0x80000

    /// What this build advertises: end-to-end DMs, groups, reactions and store-and-forward, with the ratchet's three bits,
    /// ``ratchet``, ``inlineAck`` and ``cryptoV3``, and ``linkProof`` (`0x4015F`, ADR 2026-09.n393, ADR 2026-10.ehe6, ADR
    /// 2026-10.5sk9, knit-ios #25). Android reads the reactions bit for diagnostics only, and the ratchet's from our signed
    /// profile alone (`CryptoScheme.kt:11-13`), which carries them only beside our prekey with the ratchet's switch on
    /// (`MeshConfiguration.capabilities`); the HELLO and the advert carry this set whatever the switch says, as hints
    /// nothing seals by. ``linkProof`` rides the signed profile whatever the switch says, since a peer reads it there to
    /// know this node must prove its id. Never ``fastCompact`` or ``frameTranscode``, which are fast-plane encodings this
    /// port has no plane for, and never ``doorbell`` or ``blobHave``: those are the link's to claim, in the HELLO alone.
    public static let local: Self = [.endToEnd, .groups, .reactions, .storeForward, .ratchet, .inlineAck, .cryptoV3, .linkProof]

    /// The ratchet's bits: what our signed profile drops with the switch off or no prekey kept, so it reads as it did
    /// before the ratchet but for ``linkProof`` (`0x4000F`), since `CAP_RATCHET` promises a published prekey
    /// (`MeshManager.kt:2963-2979`).
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
    /// (Kotlin's `Long.toString(16)`): `fff` for Android, `4015f` for us.
    public var hex: String { String(rawValue, radix: Self.hexRadix) }

    private static let hexRadix = 16
}
