public import KnitWire

/// The plaintext of a ctl 11 as Android seals one, padded to one size (`PresenceKeyFrame.content`,
/// `mesh/crypto/PresenceKeyFrame.kt:20-65` at knit-next `cad69c77b`), for the tests that hand an iPhone a contact's presence
/// keys. Test-only: this port sends no ctl 11 (ADR 2026-11.sv5t), so nothing in `Sources/` builds one.
public enum PresenceKeyFrame {
    /// Every ctl 11 plaintext is this long, in the named layout, before the AEAD's tag (`PLAINTEXT_BYTES`).
    public static let plaintextBytes = 128

    // CBOR: the pad's text key "p" (one header byte and one letter) and a byte string's header, one byte below 24 bytes, two
    // below 256 (`:30-34`).
    private static let padKeyBytes = 2
    private static let shortHeaderMax = 23
    private static let maxPad = 255

    /// The padded content handing over `keys`, one key or two with the higher generation as the next pair, lowest generation
    /// first (`content`, `:42-64`). A gap CBOR cannot spell lands one byte long, as Android's does.
    public static func content(_ keys: [(generation: Int64, key: [UInt8])]) -> MessageContent {
        precondition((1...2).contains(keys.count), "a presence-key frame carries one or two keys")
        let first = keys[0]
        let next = keys.count > 1 ? keys[1] : nil
        let bare = PresenceKeyPayload(generation: first.generation, key: first.key, nextGeneration: next?.generation, nextKey: next?.key)
        let unpadded = MessageContent(body: "", ctl: MessageContent.Control.presenceKey, pk: bare).encoded.count
        let gap = plaintextBytes - unpadded - padKeyBytes
        let padLength: Int? =
            if gap < 1 {
                nil
            } else if gap - 1 <= shortHeaderMax {
                gap - 1
            } else if gap - 2 > shortHeaderMax {
                gap - 2
            } else {
                shortHeaderMax + 1
            }
        var payload = bare
        payload.pad = padLength.map { [UInt8](repeating: 0, count: min($0, maxPad)) }
        return MessageContent(body: "", ctl: MessageContent.Control.presenceKey, pk: payload)
    }
}
