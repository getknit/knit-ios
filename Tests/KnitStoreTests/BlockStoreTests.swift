import KnitStore
import KnitTestSupport
import Testing

/// The block list, run against every implementation (`SettingsStoreTest`'s `block adds node id and device tag, unblock
/// removes both`, ADR 2026-10.5wgg).
@Suite struct BlockStoreTests {
    private static let kinds = RepositoryKind.allCases

    private let bob = fixtureNodeId(2)
    private let carol = fixtureNodeId(3)

    @Test(arguments: kinds)
    func nobodyIsBlockedAtFirst(kind: RepositoryKind) throws {
        let store = try kind.make().blocks
        #expect(store.blockedNodeIds().isEmpty)
        #expect(!store.isBlocked(deviceTag: "0011223344556677"))
    }

    @Test(arguments: kinds)
    func aBlockAddsTheNodeIdAndTheDeviceTagAndAnUnblockRemovesBoth(kind: RepositoryKind) throws {
        let store = try kind.make().blocks
        store.block(bob, deviceTag: "0011223344556677")
        store.block(bob, deviceTag: "0011223344556677")
        store.block(carol, deviceTag: nil)
        #expect(store.blockedNodeIds() == [bob, carol], "blocking twice blocks once")
        #expect(store.isBlocked(deviceTag: "0011223344556677"))
        store.unblock(bob, deviceTag: "0011223344556677")
        #expect(store.blockedNodeIds() == [carol])
        #expect(!store.isBlocked(deviceTag: "0011223344556677"))
        store.unblock(carol, deviceTag: nil)
        store.unblock(carol, deviceTag: nil)
        #expect(store.blockedNodeIds().isEmpty, "unblocking twice is harmless")
    }

    @Test(arguments: kinds)
    func anUnblockKeepsEveryoneElseTheSameTagBlocked(kind: RepositoryKind) throws {
        // The device-tag continuity block: the same phone under new keys. Unblocking one id leaves the other.
        let store = try kind.make().blocks
        store.block(bob, deviceTag: "0011223344556677")
        store.block(carol, deviceTag: "0011223344556677")
        store.unblock(bob, deviceTag: "0011223344556677")
        #expect(store.blockedNodeIds() == [carol])
        #expect(!store.isBlocked(deviceTag: "0011223344556677"))
    }

    @Test(arguments: kinds)
    func deviceTagsCompareByTheirBytes(kind: RepositoryKind) throws {
        // ADR 2026-09.jc2x: a tag arrives in a peer's profile, and the Kelvin sign is not a K on Android.
        let store = try kind.make().blocks
        store.block(bob, deviceTag: "K")
        #expect(store.isBlocked(deviceTag: "K"))
        #expect(!store.isBlocked(deviceTag: "\u{212A}"))
        #expect(!store.isBlocked(deviceTag: "K\u{0}x"), "nor is a tag its own prefix")
    }
}
