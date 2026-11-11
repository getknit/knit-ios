import KnitTestSupport
import KnitWire
import Testing

/// A ctl 11's padding (`PresenceKeyFrame.content`, `mesh/crypto/PresenceKeyFrame.kt:34-64` at knit-next `cad69c77b`; ADR
/// 2026-11.prsp): one key or two, the named plaintext is 128 bytes, so a listener on a cleartext link cannot tell whether
/// the next key rode along.
@Suite struct PresenceKeyFrameTests {
    private let generation: Int64 = 1_756_200_000_000

    @Test func oneKeyOrTwoPadToTheSameLength() throws {
        let one = PresenceKeyFrame.content(current: (generation, fixtureBytes(32, seed: 1)), next: nil)
        let two = PresenceKeyFrame.content(
            current: (generation, fixtureBytes(32, seed: 1)), next: (generation + 1, fixtureBytes(32, seed: 2)))
        for content in [one, two] {
            #expect(content.encoded.count == PresenceKeyFrame.plaintextBytes)
            #expect(content.ctl == MessageContent.Control.presenceKey && content.body.isEmpty)
            #expect(content.pk?.pad?.allSatisfy { $0 == 0 } == true)
            #expect(try MessageContent(decoding: content.encoded) == content, "it reads back to itself")
            #expect(MessageContentV2.encode(content) == nil, "named only: v2")
        }
        #expect(two.pk?.nextGeneration == generation + 1 && two.pk?.nextKey == fixtureBytes(32, seed: 2))
        #expect(one.pk?.nextGeneration == nil && one.pk?.nextKey == nil)
    }

    /// Only a generation shorter than a millisecond clock's nine encoded bytes can make the gap CBOR cannot spell, which
    /// lands one byte over, never under.
    @Test func aShortGenerationLandsAtTheLengthOrOneByteOver() {
        for small in [Int64(1), 24, 255, 65_536, 4_294_967_296] {
            let size = PresenceKeyFrame.content(current: (small, fixtureBytes(32, seed: 1)), next: (small + 1, fixtureBytes(32, seed: 2)))
                .encoded.count
            #expect([PresenceKeyFrame.plaintextBytes, PresenceKeyFrame.plaintextBytes + 1].contains(size), "g=\(small): \(size)")
        }
    }
}
