import Foundation
public import KnitCrypto
public import KnitStore
import KnitSync
import KnitWire

/// A peer's state directory: its identity and its ratchet prekeys in `identity` (mode 0600, in a 0700 directory) and
/// its own profile in `profile.json`, including the version and publish stamp. Keeping those two across restarts
/// matters: Android keeps the newest version it saw, so a peer that forgot its version would publish edits nobody took.
///
/// Everything else, custody, peers and messages, lives in memory and starts empty.
public struct PeerState: Sendable {
    /// The directory.
    public let directory: String

    /// The state in `directory`.
    public init(directory: String) {
        self.directory = directory
    }

    /// Where the private keys live.
    public var identity: FileSecretStore {
        FileSecretStore(path: directory + "/identity")
    }

    /// The stored identity, made and kept first if there is none.
    public func loadIdentity() throws(SecretStoreError) -> IdentityKeys.Loaded {
        try IdentityKeys.load(from: identity)
    }

    /// The ratchet prekeys `keys` keeps beside it in `identity`, read without writing anything: load the identity first
    /// (ADR 2026-10.5sk9).
    public func loadPrekeys(for keys: IdentityKeys) throws(SecretStoreError) -> PrekeyRing {
        try PrekeyRing.load(for: keys, from: identity)
    }

    /// Keeps `keys` as this peer's identity, and forgets the old identity's profile clocks with it. The name and the
    /// photo stay, the photo still kept in `avatar.jpg`.
    public func replaceIdentity(with keys: IdentityKeys) throws(SecretStoreError) {
        try identity.write(keys.storedForm)
        let profile = profileStore()
        let old = profile.load()
        profile.save(OwnProfile(name: old.name, avatarHash: old.avatarHash))
    }

    /// The own profile, kept in `profile.json`.
    public func profileStore() -> FileOwnProfileStore {
        FileOwnProfileStore(path: directory + "/profile.json")
    }

    /// Our own photo, kept in `avatar.jpg` beside the profile that names it, since the peer's blobs live in memory and
    /// it must still serve the hash `profile.json` advertises after a restart (ADR 2026-10.nh55).
    public var avatarPath: String { directory + "/avatar.jpg" }
}

/// An ``OwnProfileStore`` in one JSON file, rewritten atomically on every save. A file that is missing or does not
/// parse reads as a fresh profile.
public final class FileOwnProfileStore: OwnProfileStore {
    private struct Stored: Codable {
        var name: String
        var status: String
        var openToChat: Bool
        var version: Int64
        var publishedAt: Int64
        /// Absent in a file from before photos, which reads as none.
        var avatarHash: String?
        /// The ratchet prekey the publish carries; absent in a file from before prekeys, or when it carries none.
        var prekeyId: Int?
    }

    private static let fileMode = 0o600

    /// The file's path.
    public let path: String
    private let cached: Lock<OwnProfile>
    /// Why the last save failed, if it did; the peer logs it.
    public var lastError: String? { failure.withLock { $0 } }
    private let failure = Lock<String?>(nil)

    /// The store at `path`, read once now.
    public init(path: String) {
        self.path = path
        let stored = FileManager.default.contents(atPath: path).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        let profile = stored.map { saved in
            OwnProfile(
                name: saved.name,
                status: saved.status,
                openToChat: saved.openToChat,
                version: saved.version,
                publishedAt: saved.publishedAt,
                avatarHash: saved.avatarHash.flatMap(BlobHash.init),
                prekeyId: saved.prekeyId
            )
        }
        cached = Lock(profile ?? OwnProfile())
    }

    public func load() -> OwnProfile {
        cached.withLock { $0 }
    }

    /// Always the profile held: the file was read once, when the store was made, and one that did not parse is a fresh
    /// profile by design.
    public func loadIfReadable() -> OwnProfile? {
        load()
    }

    public func save(_ profile: OwnProfile) {
        cached.withLock { $0 = profile }
        let stored = Stored(
            name: profile.name,
            status: profile.status,
            openToChat: profile.openToChat,
            version: profile.version,
            publishedAt: profile.publishedAt,
            avatarHash: profile.avatarHash?.string,
            prekeyId: profile.prekeyId
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(stored).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: Self.fileMode], ofItemAtPath: path)
            failure.withLock { $0 = nil }
        } catch {
            failure.withLock { $0 = "cannot write \(path): \(error)" }
        }
    }
}
