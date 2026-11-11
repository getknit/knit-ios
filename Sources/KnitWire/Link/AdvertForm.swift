/// The shape of an advertised form: the 16 bytes at offset 1 of an advert (``AdvertPayload/advertised``), a node id when
/// clear and a rotating tag when blinded (knit-next ADR 2026-11.xp6d; ADR 2026-11.sv5t).
///
/// Only the shape lives here. The tag's derivation, which needs the presence key's HMAC, is KnitCrypto's.
public enum AdvertForm {
    /// A tag's length: an advert's bytes 1–16.
    public static let tagByteCount = 16
    /// A tag's fixed first byte (`0xCE`): with the next byte and a half, the `zzzz` of its base32 form.
    private static let prefix0: UInt8 = 0xCE
    /// A tag's fixed second byte (`0x73`).
    private static let prefix1: UInt8 = 0x73
    /// The byte whose high nibble ends the prefix.
    private static let splitByte = 2
    private static let highNibble: UInt8 = 0xF0
    /// The prefix's last four bits, `1001`, in the split byte's high nibble.
    private static let prefix2High: UInt8 = 0x90

    /// A tag no presence key derives: the prefix over the low 108 bits of `high` and `low`, big-endian, which a caller draws
    /// at random (`TagSchedule.randomTag`, `TagSchedule.kt:180-186` at knit-next `cad69c77b`). It resolves to nobody.
    public static func tag(prefixing high: UInt64, _ low: UInt64) -> NodeId {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(tagByteCount)
        for word in [high, low] {
            for shift in stride(from: UInt64.bitWidth - UInt8.bitWidth, through: 0, by: -UInt8.bitWidth) {
                bytes.append(UInt8(truncatingIfNeeded: word >> UInt64(shift)))
            }
        }
        bytes[0] = prefix0
        bytes[1] = prefix1
        bytes[splitByte] = prefix2High | (bytes[splitByte] & ~highNibble)
        return NodeId(sixteen: bytes)
    }

    /// Whether `bytes` are ``tagByteCount`` long and carry a tag's 20 fixed bits: `CE 73 9_`. Says nothing about whose
    /// tag it is. Total. `BlindTag.hasPrefix`, `BlindTag.kt:131-135` at knit-next `cad69c77b`.
    public static func hasTagPrefix(_ bytes: [UInt8]) -> Bool {
        bytes.count == tagByteCount
            && bytes[0] == prefix0
            && bytes[1] == prefix1
            && bytes[splitByte] & highNibble == prefix2High
    }
}
