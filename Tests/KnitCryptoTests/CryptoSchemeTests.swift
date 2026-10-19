import KnitCrypto
import KnitWire
import Testing

/// The one v3 gate, ported from knit-next's `CryptoSchemeTest` (at `ac491f4c`): both ratchet bits on the pinned profile,
/// or v2.
@Suite struct CryptoSchemeTests {
    /// Android's own `Protocol.LOCAL_CAPABILITIES` (`Protocol.kt:161-164`), `0x2fff`, which the Kotlin test reads.
    private static let androidLocal: Capabilities = [
        .endToEnd, .groups, .reactions, .storeForward, .ratchet, .fastCompact, .inlineAck, .frameTranscode, .cryptoV3,
        .files, .linkPreview, .directTransfer, .blobHave,
    ]

    @Test func v3NeedsBothBitsAndNothingElse() {
        let both = Capabilities([.ratchet, .cryptoV3]).rawValue
        #expect(CryptoScheme.forCapabilities(both) == EncEnvelope.Version.compactRatchet)
        #expect(CryptoScheme.forCapabilities(Self.androidLocal.rawValue) == EncEnvelope.Version.compactRatchet)
        #expect(
            CryptoScheme.forCapabilities(Capabilities.cryptoV3.rawValue) == EncEnvelope.Version.ratchet,
            "a v3 claim without the ratchet is no scheme at all"
        )
        #expect(CryptoScheme.forCapabilities(Capabilities.ratchet.rawValue) == EncEnvelope.Version.ratchet)
        let ratchetOnly = Self.androidLocal.subtracting(.cryptoV3).rawValue
        #expect(CryptoScheme.forCapabilities(ratchetOnly) == EncEnvelope.Version.ratchet)
        #expect(CryptoScheme.forCapabilities(0) == EncEnvelope.Version.ratchet)
        #expect(CryptoScheme.forCapabilities(nil) == EncEnvelope.Version.ratchet)
    }

    /// Kotlin reads a `PeerEntity`; this port's pinned peer is `PeerRecord`, whose `capabilities` is this argument. The
    /// record's own reader lands with the phase that seals DMs (ADR 2026-10.5sk9).
    @Test func theProfileReadIsTheOnlySource() {
        #expect(CryptoScheme.readsCryptoV3(Self.androidLocal.rawValue))
        #expect(!CryptoScheme.readsCryptoV3(Capabilities.ratchet.rawValue))
        #expect(!CryptoScheme.readsCryptoV3(nil), "an unpinned peer")
        // This build's own bits, `0x15F` since the flip, read v3; without the ratchet's, `0xF`, they read neither.
        #expect(CryptoScheme.readsCryptoV3(Capabilities.local.rawValue))
        #expect(!CryptoScheme.readsCryptoV3(Capabilities.local.subtracting(.ratchetSuite).rawValue))
    }
}
