import KnitCrypto
import KnitWire

@testable import KnitMesh

/// What the blinded-advert reader's ports share (knit-next's `AdvertAliasesTest`, `ExpectedTagTableTest` and their
/// neighbours at `cad69c77b`): seeded keys, named ids, tags, and the two clocks a test moves by hand.
struct BlindFixture {
    /// The wall clock Kotlin's tests start at: 2027-01-15, mid-slot.
    static let wall: Int64 = 1_800_000_000_000
    /// The monotonic clock they start at.
    static let now: Int64 = 1_000_000
    /// Slots in a reader's window: 32 back, the current one, 2 ahead.
    static let windowSlots = Int(BlindTag.windowPastSlots + 1 + BlindTag.windowAheadSlots)

    private var random = SeededGenerator(seed: 285)

    /// A fresh presence key.
    mutating func key() -> PresenceKey {
        var bytes = [UInt8](repeating: 0, count: PresenceKey.byteCount)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...UInt8.max, using: &random)
        }
        return required(PresenceKey(bytes: bytes))
    }

    /// A node id named for a test, as Kotlin's `NodeId.derive(name)`: the name's bytes, padded to 16.
    static func id(_ name: String) -> NodeId {
        let bytes = Array(name.utf8.prefix(NodeId.byteCount))
        return required(NodeId(bytes: bytes + [UInt8](repeating: 0x5A, count: NodeId.byteCount - bytes.count)))
    }

    /// A 26-character form made of one text padded with `a`, as Kotlin's tests write `"zzzzq"`: canonical, since `a` ends
    /// it.
    static func form(_ text: String) -> NodeId {
        required(NodeId(text + String(repeating: "a", count: NodeId.length - text.count)))
    }

    /// `owner`'s tag under `key` for `slot` and `restart`.
    static func tag(_ key: PresenceKey, owner: NodeId, slot: Int64, restart: Int = 0) -> NodeId {
        required(NodeId(bytes: BlindTag.tag(key: key, owner: owner.bytes, slot: slot, restart: restart) ?? []))
    }

    /// A blinded form.
    static func blinded(_ tag: NodeId) -> AdvertOrder.Form {
        AdvertOrder.Form(advertised: tag, blinded: true)
    }
}

/// `value`, which the fixture's inputs always make.
func required<T>(_ value: T?, _ what: String = "a fixture value") -> T {
    guard let value else {
        fatalError("\(what) was nil")
    }
    return value
}

/// Both clocks, moved by hand.
final class BlindClocks {
    var now = BlindFixture.now
    var wall = BlindFixture.wall

    /// A resolver reading these clocks.
    func aliases<L: Hashable>(
        _: L.Type,
        configuration: AdvertAliases<L>.Configuration = AdvertAliases<L>.Configuration()
    ) -> AdvertAliases<L> {
        AdvertAliases(now: { [weak self] in self?.now ?? 0 }, wall: { [weak self] in self?.wall ?? 0 }, configuration: configuration)
    }
}
