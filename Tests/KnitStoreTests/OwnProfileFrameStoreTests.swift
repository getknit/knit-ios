import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// The frame our profile was published as, kept beside the profile in every own-profile store (ADR 2026-11.xfcq): its two
/// byte strings exactly as kept, whatever bytes they hold, one frame at a time, untouched by a profile's save, and put back
/// by a unit that is undone.
@Suite struct OwnProfileFrameStoreTests {
    private static let kinds = RepositoryKind.allCases

    /// A frame whose bytes are arbitrary, NULs and a non-UTF-8 byte among them: the store keeps bytes, never text.
    private static let odd = WireEnvelope(
        sig: [0x00, 0xFF, 0x00, 0x7F] + fixtureBytes(60, seed: 1), signed: [0x00, 0xC3, 0x28, 0x00, 0x00])

    @Test(arguments: kinds)
    func aKeptFrameRoundTripsByteForByteAndIsReplacedAndForgotten(kind: RepositoryKind) throws {
        let store = try kind.make().ownProfile
        #expect(store.keptFrame() == .absent, "nothing kept before a signing")
        #expect(store.keep(Self.odd))
        #expect(store.keptFrame() == .kept(Self.odd))
        let next = WireEnvelope(sig: fixtureBytes(64, seed: 2), signed: fixtureBytes(900, seed: 3))
        #expect(store.keep(next))
        #expect(store.keptFrame() == .kept(next), "one frame, replaced")
        #expect(store.keep(nil))
        #expect(store.keptFrame() == .absent)
    }

    @Test(arguments: kinds)
    func onlyTheTwoByteStringsAreKept(kind: RepositoryKind) throws {
        let store = try kind.make().ownProfile
        store.keep(WireEnvelope(ttl: 3, hops: 5, relay: false, sig: Self.odd.sig, signed: Self.odd.signed))
        #expect(store.keptFrame() == .kept(Self.odd), "read back flooded, ttl 8 and hops 0")
    }

    @Test(arguments: kinds)
    func aProfilesSaveLeavesTheKeptFrame(kind: RepositoryKind) throws {
        let store = try kind.make().ownProfile
        store.keep(Self.odd)
        store.save(OwnProfile(name: "Alice", version: 7, publishedAt: 9))
        store.save(OwnProfile(name: "Al", version: 8, publishedAt: 10))
        #expect(store.keptFrame() == .kept(Self.odd), "the profile's row is replaced whole, the frame's is its own")
    }

    @Test(arguments: kinds)
    func aUnitUndoneLeavesTheKeptFrameAsItFoundIt(kind: RepositoryKind) throws {
        let stores = try kind.make()
        stores.ownProfile.keep(Self.odd)
        let undone = stores.transactor.atomically { () -> Int? in
            stores.ownProfile.keep(WireEnvelope(sig: [1], signed: [2]))
            return nil
        }
        #expect(undone == .abandoned)
        #expect(stores.ownProfile.keptFrame() == .kept(Self.odd))
    }
}
