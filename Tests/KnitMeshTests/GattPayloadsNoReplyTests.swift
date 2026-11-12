import KnitCrypto
import KnitMesh
import KnitTestSupport
import KnitWire
import Testing

/// `GattPayloads`' rule 5, the seal's forget-once (the `link-seal` contract, §7, revisions 1 and 2): a plain dial that got
/// no reply forgets a clear payload without `FLAG_LINK_SEAL`, once per address, and nothing else.
@Suite struct GattPayloadsNoReplyTests {
    /// A ``GattPayloads`` behind a reference, so `#expect` can check what a mutating call answers.
    private final class Reads {
        var state = GattPayloads(
            configuration: GattPayloads.Configuration(
                readTimeoutMilliseconds: 100, retryMilliseconds: 1000, strangerRetryMilliseconds: 5000))

        func begin(_ address: RadioAddress, now: Int64) -> Bool {
            state.begin(address, now: now)
        }

        func noReply(at address: RadioAddress) -> Bool {
            state.noReply(at: address)
        }

        func forgetPastEdge(wall: Int64) -> [RadioAddress] {
            state.forgetPastEdge(wall: wall, linked: [])
        }
    }

    private static let phone = RadioAddress("phone")
    private static let other = RadioAddress("other")
    private static let payload = AdvertPayload(capabilities: 0xFFF, nodeId: fixtureNodeId(2), digestCue: 0, psm: 0x81)
    private static let blinded = AdvertPayload(
        capabilities: 0xFFF,
        advertised: AdvertForm.tag(prefixing: 7, 7),
        digestCue: 0,
        psm: 0x81,
        flags: AdvertPayload.writtenFlags(dialsGattPeers: true, blinded: true, seals: false)
    )
    /// Mid-slot on the wall clock.
    private static let wall: Int64 = 1_800_000_000_000
    private static let edge = (BlindTag.slotOf(wallMilliseconds: wall) + 1) * BlindTag.slotMilliseconds

    private func read(_ reads: Reads, _ address: RadioAddress, _ payload: AdvertPayload = Self.payload, now: Int64) {
        #expect(reads.begin(address, now: now))
        reads.state.finish(address, .read(payload), now: now, wall: 0)
    }

    private func readBlinded(_ reads: Reads, wall: Int64 = Self.wall) {
        #expect(reads.begin(Self.phone, now: 0))
        reads.state.finish(Self.phone, .read(Self.blinded), now: 0, wall: wall)
    }

    private static let sealing = AdvertPayload(
        capabilities: 0xFFF, nodeId: fixtureNodeId(2), digestCue: 0, psm: 0x81, flags: AdvertPayload.linkSealFlag)

    @Test func aPlainDialWithNoReplyForgetsAnUnflaggedPayloadOnce() {
        let reads = Reads()
        read(reads, Self.phone, now: 0)
        #expect(reads.noReply(at: Self.phone))
        #expect(reads.state.payload(of: Self.phone) == nil)
        #expect(reads.begin(Self.phone, now: 10), "read again at its next advert")
        reads.state.finish(Self.phone, .read(Self.payload), now: 10, wall: 0)
        #expect(!reads.noReply(at: Self.phone), "still unflagged: kept, once is enough")
        #expect(reads.state.payload(of: Self.phone) == Self.payload)
        #expect(!reads.noReply(at: Self.other), "nothing read there")
    }

    @Test func aFlaggedPayloadIsNeverForgottenForANoReply() {
        let reads = Reads()
        read(reads, Self.phone, Self.sealing, now: 0)
        #expect(!reads.noReply(at: Self.phone), "revision 2: a no-reply says nothing of the flag")
        #expect(reads.state.payload(of: Self.phone) == Self.sealing)
    }

    @Test func theMarkClearsWhenAReadFindsTheFlagOrAnotherRuleForgets() {
        let reads = Reads()
        read(reads, Self.phone, now: 0)
        #expect(reads.noReply(at: Self.phone))
        read(reads, Self.phone, Self.sealing, now: 10)
        reads.state.forget(Self.phone)
        read(reads, Self.phone, now: 20)
        #expect(reads.noReply(at: Self.phone), "the flag was read, so the mark went")
        read(reads, Self.phone, now: 30)
        reads.state.forget(Self.phone)
        read(reads, Self.phone, now: 40)
        #expect(reads.noReply(at: Self.phone), "another rule forgot the address, so the mark went")
    }

    /// Rule 5 takes clear payloads only (the `blind-gatt-reads` contract, §6, Android's `forgetUnsealed`): a blinded one
    /// that lacks `FLAG_LINK_SEAL` stays for a plain dial's silence, as rule 4 forgets it every slot anyway.
    @Test func aBlindedPayloadIsNeverForgottenForANoReply() {
        let reads = Reads()
        readBlinded(reads)
        #expect(!reads.noReply(at: Self.phone))
        #expect(reads.state.payload(of: Self.phone) == Self.blinded)
        #expect(reads.forgetPastEdge(wall: Self.edge + 70_000) == [Self.phone], "rule 4 still forgets it at its edge")
    }
}
