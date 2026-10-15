import KnitWire

/// Which form of the ratchet a sealed DM toward a peer takes, decided in one place (`CryptoScheme` in knit-next's
/// `mesh/crypto/CryptoScheme.kt:7-21`, knit-next ADR 059). Both bits ride the signed profile beside the prekey, so a peer
/// never claims v3 without the means to open it, and a peer whose pinned profile predates the bit keeps receiving v2.
/// Read the pinned profile's capabilities (`PeerRecord.capabilities`), never a link's copy.
///
/// It chooses between v2 and v3 only. Whether a DM takes the ratchet at all is for `MeshConfiguration.ratchet`, the
/// peer's `CAP_RATCHET` and its prekey, which a later phase wires (ADR 2026-10.5sk9).
public enum CryptoScheme {
    /// ``EncEnvelope/Version/compactRatchet`` when `capabilities` carries both ``Capabilities/ratchet`` and
    /// ``Capabilities/cryptoV3``, else ``EncEnvelope/Version/ratchet`` (`forCapabilities`, `:15-20`). A peer with no
    /// pinned profile, `nil`, gets v2.
    public static func forCapabilities(_ capabilities: Int64?) -> Int {
        let bits = Capabilities(rawValue: capabilities ?? 0)
        return bits.isSuperset(of: [.ratchet, .cryptoV3]) ? EncEnvelope.Version.compactRatchet : EncEnvelope.Version.ratchet
    }

    /// Whether a peer with these pinned capabilities opens v3 (`readsCryptoV3`, `:23-24`): `false` for an unpinned peer.
    public static func readsCryptoV3(_ capabilities: Int64?) -> Bool {
        forCapabilities(capabilities) == EncEnvelope.Version.compactRatchet
    }
}
