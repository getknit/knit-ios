import KnitSync
public import KnitWire

/// What this node publishes about itself, and the two clocks that make a published profile propagate
/// (`SettingsStore.profileVersion` and `profilePublishedAt` in knit-next).
public struct OwnProfile: Sendable, Equatable {
    /// The display name; empty shows the alias.
    public var name: String
    /// The status line.
    public var status: String
    /// Whether this node invites DMs from people it has not met.
    public var openToChat: Bool
    /// The edit clock receivers order profiles by. An edit sets it to `max(now, version + 1)`; a republish
    /// leaves it alone, so a republish is never mistaken for an edit.
    public var version: Int64
    /// The publish stamp: the profile frame's `sentAt` and the tail of its id, `profile-<nodeId>-<stamp>`. It
    /// moves on every edit and every 12-hour republish, which keeps the frame inside custody's 24-hour window.
    public var publishedAt: Int64
    /// Our profile photo, whose bytes the blob store holds (`SettingsStore.ownAvatarHash`), or `nil` for none.
    public var avatarHash: BlobHash?
    /// The id of the ratchet prekey this publish carries, or `nil` for none (ADR 2026-10.5sk9). It is part of what is
    /// published, so a stamp names one payload: a new prekey, or the ratchet's switch turned either way, moves the stamp,
    /// and moves the version too once the profile has been edited. Android reads its newest prekey at each signing
    /// instead (`MeshManager.kt:2963-2965`).
    public var prekeyId: Int?
    /// The capabilities the publish under ``publishedAt`` carries, or `nil` when none are recorded: a profile saved by a
    /// build before this field, or never published (`SettingsStore.ownProfileCapabilities` in knit-next, knit-ios #25). A
    /// start whose profile would carry other capabilities, or finds none recorded, publishes again as an edit, so the first
    /// profile with a new bit is strictly newer than every one without it, and a peer's row, whose capabilities follow its
    /// presentation's version, cannot be taken back by an older frame.
    public var capabilities: Capabilities?

    /// A profile; the defaults are a fresh identity's, nothing set and nothing published.
    public init(
        name: String = "",
        status: String = "",
        openToChat: Bool = false,
        version: Int64 = 0,
        publishedAt: Int64 = 0,
        avatarHash: BlobHash? = nil,
        prekeyId: Int? = nil,
        capabilities: Capabilities? = nil
    ) {
        self.name = name
        self.status = status
        self.openToChat = openToChat
        self.version = version
        self.publishedAt = publishedAt
        self.avatarHash = avatarHash
        self.prekeyId = prekeyId
        self.capabilities = capabilities
    }
}

/// Where ``OwnProfile`` persists. The clocks must survive a restart, or a relaunch would mint a new frame id for
/// an unchanged profile.
public protocol OwnProfileStore: AnyObject, Sendable {
    /// The saved profile, or a fresh one.
    func load() -> OwnProfile

    /// The saved profile, a fresh one when none is saved, or `nil` when the store cannot be read now. ``load()``
    /// answers a fresh profile then too, which a caller that acts on a fresh profile, as a reinstall's prekey does, must
    /// not take for one (ADR 2026-10.5sk9).
    func loadIfReadable() -> OwnProfile?

    /// Saves the profile.
    func save(_ profile: OwnProfile)

    /// The profile frame we published under our current stamp, as ``keep(_:)`` kept it: none, or a store that cannot be
    /// read now, which is never a reason to sign the stamp again (ADR 2026-11.xfcq, after knit-next ADR 2026-11.khhj).
    func keptFrame() -> KeptProfileFrame

    /// Keeps `frame`'s signature and signed bytes, byte for byte, in place of any frame kept before, or forgets the kept
    /// frame with `nil`. Only those two are kept: the frame reads back flooded, `ttl` 8 and `hops` 0. Answers whether the
    /// write landed.
    @discardableResult
    func keep(_ frame: WireEnvelope?) -> Bool
}

/// What ``OwnProfileStore/keptFrame()`` read (ADR 2026-11.xfcq).
///
/// Our own profile frame is kept outside custody because custody's quotas evict our frames as they evict anyone's, and a
/// stamp signed a second time is a second set of bytes under an id peers already hold: CryptoKit randomizes Ed25519
/// signatures, and the profile read at a later signing can carry another prekey or device tag (knit-next ADR 2026-11.khhj).
public enum KeptProfileFrame: Sendable, Equatable {
    /// The frame kept, around its signature and signed bytes as they were stored.
    case kept(WireEnvelope)
    /// No frame is kept: a node that has signed none yet, a database from before the frame was kept, or one forgotten.
    case absent
    /// The store could not be read now.
    case unreadable
}

/// An ``OwnProfileStore`` in memory.
public final class MemoryOwnProfileStore: OwnProfileStore {
    private let profile: Lock<OwnProfile>
    private let frame = Lock<WireEnvelope?>(nil)

    /// A store holding `profile`, and no kept frame.
    public init(_ profile: OwnProfile = OwnProfile()) {
        self.profile = Lock(profile)
    }

    public func load() -> OwnProfile {
        profile.withLock { $0 }
    }

    /// Always the profile held: memory never fails to read.
    public func loadIfReadable() -> OwnProfile? {
        load()
    }

    public func save(_ profile: OwnProfile) {
        self.profile.withLock { $0 = profile }
    }

    /// The frame held: memory never fails to read.
    public func keptFrame() -> KeptProfileFrame {
        frame.withLock { $0 }.map(KeptProfileFrame.kept) ?? .absent
    }

    @discardableResult
    public func keep(_ frame: WireEnvelope?) -> Bool {
        self.frame.withLock { $0 = frame.map { WireEnvelope(sig: $0.sig, signed: $0.signed) } }
        return true
    }
}

extension MemoryOwnProfileStore: Checkpointing {
    /// The profile held, and the kept frame.
    public func checkpoint() -> StoreCheckpoint {
        let held = load()
        let kept = frame.withLock { $0 }
        return StoreCheckpoint { [self] in
            save(held)
            frame.withLock { $0 = kept }
        }
    }
}
