/// The plaintext of a ctl 11, padded to one size (`PresenceKeyFrame.content`, `mesh/crypto/PresenceKeyFrame.kt:18-65` at
/// knit-next `cad69c77b`; knit-next ADR 2026-11.xp6d; ADR 2026-11.prsp). The links are readable to a listener in radio
/// range until they are encrypted (knit-ios #51), so a frame that carried the next key and one that did not must not differ
/// in length: the pad fills ``PresenceKeyPayload/pad`` until the whole named ``MessageContent`` plaintext is exactly
/// ``plaintextBytes`` long. Both platforms pad to the same length, since the size is what a listener compares.
///
/// What it buys: one size hides whether the next key rode along, never that a point-to-point v2 frame of this size crossed
/// the link. A ctl 11 has no compact form (``MessageContentV2/encode(_:)`` refuses `pk`), so it always seals named under v2.
public enum PresenceKeyFrame {
    /// Every ctl 11 plaintext is this long, in the named layout, before the AEAD's tag (`PLAINTEXT_BYTES`, `:20`).
    public static let plaintextBytes = 128

    // CBOR: the pad's text key "p" (one header byte and one letter) and a byte string's header, one byte below 24 bytes, two
    // below 256 (`PAD_KEY_BYTES`, `SHORT_HEADER_MAX`, `MAX_PAD`, `:24-26`).
    private static let padKeyBytes = 2
    private static let shortHeaderMax = 23
    private static let maxPad = 255
    /// A byte string's header: one byte up to ``shortHeaderMax`` bytes, two up to ``maxPad``.
    private static let shortHeaderBytes = 1
    private static let longHeaderBytes = 2

    /// One key a frame hands over: its sender's generation and its 32 bytes.
    public typealias Key = (generation: Int64, key: [UInt8])

    /// The padded content handing over `current`, and `next` as the next pair when there is one (`content`, `:34-64`): the
    /// lower generation first, as the owed keys come. A gap CBOR cannot spell (a 23-byte pad's header is one byte and a
    /// 24-byte pad's two) lands one byte long, as Android's does; only a generation of fewer than nine encoded bytes can
    /// make it, and our own generations are a millisecond clock, nine bytes each.
    public static func content(current: Key, next: Key?) -> MessageContent {
        let bare = PresenceKeyPayload(
            generation: current.generation, key: current.key, nextGeneration: next?.generation, nextKey: next?.key)
        let unpadded = MessageContent(body: "", ctl: MessageContent.Control.presenceKey, pk: bare).encoded.count
        let gap = plaintextBytes - unpadded - padKeyBytes
        let padLength: Int? =
            if gap < 1 {
                // Already at the size, a payload this build never makes: no pad field at all.
                nil
            } else if gap - shortHeaderBytes <= shortHeaderMax {
                gap - shortHeaderBytes
            } else if gap - longHeaderBytes > shortHeaderMax {
                gap - longHeaderBytes
            } else {
                // The one length CBOR cannot spell: a byte over, never under.
                shortHeaderMax + 1
            }
        var payload = bare
        payload.pad = padLength.map { [UInt8](repeating: 0, count: min($0, maxPad)) }
        return MessageContent(body: "", ctl: MessageContent.Control.presenceKey, pk: payload)
    }
}
