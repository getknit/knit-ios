import KnitWire

/// A canonical frame id derived from a readable label, so a test can still name its frames `dm-1` and `post-1` and have
/// them pass the router's id gate (``FrameId/admits(_:)``), which refuses any other shape (knit-next ADR 2026-10.9qr4).
/// The same label is always the same id, and distinct labels give distinct ids.
///
/// The port of `frameIdOf` (`TestFrameIds.kt` at knit-next `a81f2050`), which takes SHA-256's first 16 bytes. This target
/// links KnitWire alone, so here it is FNV-1a-64 over the label's UTF-8 under two offset bases, eight bytes each: a test
/// id, not a hash anyone relies on. It scrambles byte order, so a test that needs `(sentAt, id)` order at one `sentAt`
/// gives its frames distinct stamps instead.
public func frameIdOf(_ label: String) -> String {
    FrameId.text(for: fnv1a(label, basis: 0xCBF2_9CE4_8422_2325) + fnv1a(label, basis: 0x8422_2325_CBF2_9CE4))
}

private func fnv1a(_ label: String, basis: UInt64) -> [UInt8] {
    let prime: UInt64 = 0x0000_0100_0000_01B3
    var hash = basis
    for byte in label.utf8 {
        hash ^= UInt64(byte)
        hash &*= prime
    }
    return (0..<UInt64.bitWidth / UInt8.bitWidth).map { UInt8(truncatingIfNeeded: hash >> ($0 * UInt8.bitWidth)) }
}
