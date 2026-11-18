public import KnitStore
import KnitSync
public import KnitWire

/// knit-peer's `--lying` own-profile store, a trial's switch: our profile as the engine reads it names a photo we do not
/// own, so the engine signs and publishes that hash as ours, in the clear and in the sealed `CTL_PROFILE` alike. The trial
/// (`door-cap-lying-peers`, case 3) watches a far end take a peer advertising someone else's photo (ADR 2026-10.r88m, "The
/// photo ceiling", 5).
///
/// While ``advertisedPhoto`` is set, ``load()`` and ``loadIfReadable()`` answer the profile held with that hash for its
/// photo. ``save(_:)`` never keeps the lie: a profile saved naming the advertised hash is saved with the photo the store
/// holds, so the file, and a restart, only ever see our own photo. The version and publish stamp an edit moves are kept
/// as saved, so the edit that clears the switch outranks the one that set it. With nothing set, every call goes to the
/// store it wraps unchanged.
///
/// The switch sits outside every store unit: ``checkpoint()`` is the inner store's, which holds no lie, so a unit undone
/// leaves the switch as it was. The lock guards the switch alone and is released before each inner call.
public final class ForgingOwnProfileStore: OwnProfileStore, Checkpointing {
    private let inner: any OwnProfileStore & Checkpointing
    private let advertised = Lock<BlobHash?>(nil)

    /// `inner`, honest until ``advertise(_:)`` sets a hash. Hand the wrapper to `MeshStores.inMemory(ownProfileStore:)`,
    /// so the unit's checkpoint reaches the inner store through it.
    public init(wrapping inner: any OwnProfileStore & Checkpointing) {
        self.inner = inner
    }

    /// The hash our profile names while the switch is set, or `nil`.
    public var advertisedPhoto: BlobHash? { advertised.withLock { $0 } }

    /// Names `hash` as our photo from the next read on, or our own photo again with `nil`. The engine publishes nothing
    /// until an edit: flip this first, then edit, so the edit carries it.
    public func advertise(_ hash: BlobHash?) {
        advertised.withLock { $0 = hash }
    }

    // MARK: OwnProfileStore

    public func load() -> OwnProfile {
        presented(inner.load())
    }

    public func loadIfReadable() -> OwnProfile? {
        inner.loadIfReadable().map(presented)
    }

    /// Saves `profile`, with the photo the inner store holds in place of the advertised hash when it names that hash.
    public func save(_ profile: OwnProfile) {
        var kept = profile
        if let hash = advertisedPhoto, profile.avatarHash == hash {
            kept.avatarHash = inner.load().avatarHash
        }
        inner.save(kept)
    }

    /// The inner store's kept frame, unchanged: the frame the engine signed, which never carries the lie unless an edit
    /// signed it while the switch was set.
    public func keptFrame() -> KeptProfileFrame {
        inner.keptFrame()
    }

    @discardableResult
    public func keep(_ frame: WireEnvelope?) -> Bool {
        inner.keep(frame)
    }

    // MARK: Checkpointing

    public func checkpoint() -> StoreCheckpoint {
        inner.checkpoint()
    }

    private func presented(_ profile: OwnProfile) -> OwnProfile {
        guard let hash = advertisedPhoto else {
            return profile
        }
        var lying = profile
        lying.avatarHash = hash
        return lying
    }
}
