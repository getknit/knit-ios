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

    /// A profile; the defaults are a fresh identity's, nothing set and nothing published.
    public init(
        name: String = "",
        status: String = "",
        openToChat: Bool = false,
        version: Int64 = 0,
        publishedAt: Int64 = 0,
        avatarHash: BlobHash? = nil,
        prekeyId: Int? = nil
    ) {
        self.name = name
        self.status = status
        self.openToChat = openToChat
        self.version = version
        self.publishedAt = publishedAt
        self.avatarHash = avatarHash
        self.prekeyId = prekeyId
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
}

/// An ``OwnProfileStore`` in memory.
public final class MemoryOwnProfileStore: OwnProfileStore {
    private let profile: Lock<OwnProfile>

    /// A store holding `profile`.
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
}
