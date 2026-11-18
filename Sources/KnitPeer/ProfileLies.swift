import Foundation
public import KnitCrypto
public import KnitMesh
import KnitStore
public import KnitWire

/// knit-peer's two `--lying` profile switches, as the control commands drive them (`door-cap-lying-peers`, cases 3 and 4;
/// ADR 2026-10.r88m):
///
/// - `advertise-photo` (``setAdvertisedPhoto(_:)``, ``clearAdvertisedPhoto()``): our profile names someone else's photo.
///   The blob store keeps that hash's bytes back, the profile store presents the hash, and an honest edit with the
///   current name, status and openness then publishes it, in the clear and, to every confirmed ratchet session, sealed.
///   Clearing flips the store back first, then edits again, so the edit's higher version replaces both copies.
/// - `pad-profile` (``pad(signedBytes:)``, ``clearPad()``): ``ProfileForge`` signs our profile once, padded to a length,
///   and the caller sends those bytes on every link. Clearing always runs an honest edit, a forge in memory or not, at a
///   version and stamp above every forge of this run.
///
/// While either is set, a marker file, ``markerName`` in the state directory, says a lie may be on air. A peer that
/// stops with one set, or crashes, finds it at its next start, with `--lying` or without, and ``recoverAtStart(stateDirectory:mesh:stores:log:)``
/// publishes an honest profile over it. The marker holds the highest forge's clocks, so that edit outranks it.
///
/// Every edit here goes through `Mesh.updateProfile(name:status:openToChat:)`, so the engine signs, carries and floods
/// it as any edit. None of the switches is reachable from the app: this module is knit-peer's alone.
public actor ProfileLies {
    /// The marker's file name in the state directory.
    public static let markerName = "lying-profile"

    /// At most this many honest edits are run to outrank a forge. One does whenever the wall clock has moved past the
    /// forge's stamp; the second covers a clock still on it, whose first edit lands on the forge's own stamp.
    public static let maxHonestEdits = 3

    /// Why a switch did not take.
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// The forge refused.
        case forge(ProfileForge.Refusal)
        /// A new forge in the millisecond of the last, or before it: it would reuse that forge's id or not outrank it.
        case clockNotPastForge(now: Int64, forged: Int64)
        /// The marker could not be written or removed.
        case marker(String)
        /// ``maxHonestEdits`` edits left our profile at or below a forge: the wall clock is behind the forge's stamp.
        case honestEditsBelowForge(version: Int64, publishedAt: Int64, forged: ForgedClocks)

        public var description: String {
            switch self {
            case .forge(let refusal):
                refusal.description
            case .clockNotPastForge(let now, let forged):
                "the clock \(now) has not passed the last forged profile's stamp \(forged)"
            case .marker(let why):
                why
            case .honestEditsBelowForge(let version, let publishedAt, let forged):
                "our profile stayed at version \(version), stamp \(publishedAt), not above the forged version \(forged.version), "
                    + "stamp \(forged.publishedAt): the clock is behind the forge"
            }
        }
    }

    /// The highest version and stamp of the forges of a run, which an honest edit must pass.
    public struct ForgedClocks: Sendable, Equatable, Codable {
        /// The highest forged version.
        public var version: Int64
        /// The highest forged publish stamp.
        public var publishedAt: Int64

        /// Clocks of `version` and `publishedAt`.
        public init(version: Int64, publishedAt: Int64) {
            self.version = version
            self.publishedAt = publishedAt
        }

        /// The larger of each.
        func merged(with other: Self?) -> Self {
            guard let other else {
                return self
            }
            return Self(version: max(version, other.version), publishedAt: max(publishedAt, other.publishedAt))
        }

        /// Whether `profile` outranks every forge: a higher version, and a later stamp, so a different id.
        func outranked(by profile: OwnProfile) -> Bool {
            profile.version > version && profile.publishedAt > publishedAt
        }
    }

    /// What the marker holds: the forges' clocks, or `nil` when only `advertise-photo` is set.
    private struct Marker: Codable {
        var forged: ForgedClocks?
    }

    private let mesh: Mesh
    private let stores: MeshStores
    private let profile: ForgingOwnProfileStore
    private let blobs: LyingBlobStore?
    private let identity: IdentityKeys
    private let clock: any MeshClock
    private let markerPath: String
    private let log: any KnitLog

    /// The forge sent on air now, or `nil`.
    public private(set) var paddedProfile: ProfileForge.Forged?
    /// The clocks of every forge since the last honest edit outranked them, kept until one does.
    private var forged: ForgedClocks?

    /// The switches over `mesh`, whose stores are `stores`, its own profile read through `profile` and its blobs, when
    /// given, through `blobs`, which keeps an advertised photo's bytes back. `identity` and `clock` are the mesh's own; the
    /// marker is written in `stateDirectory`.
    public init(
        mesh: Mesh,
        stores: MeshStores,
        profile: ForgingOwnProfileStore,
        blobs: LyingBlobStore?,
        identity: IdentityKeys,
        clock: any MeshClock,
        stateDirectory: String,
        log: any KnitLog = SilentLog()
    ) {
        self.mesh = mesh
        self.stores = stores
        self.profile = profile
        self.blobs = blobs
        self.identity = identity
        self.clock = clock
        self.log = log
        markerPath = Self.markerPath(in: stateDirectory)
    }

    /// The photo our profile advertises in place of our own, or `nil`.
    public var advertisedPhoto: BlobHash? { profile.advertisedPhoto }

    // MARK: advertise-photo

    /// Advertises `hash` as our photo: the marker first, then its bytes kept back, the profile store flipped, and an edit
    /// that publishes it. An edit that cannot outrank a forge still leaves the switch set.
    public func setAdvertisedPhoto(_ hash: BlobHash) async throws(Failure) {
        try writeMarker()
        if let previous = profile.advertisedPhoto, previous != hash {
            blobs?.release(previous)
        }
        blobs?.withhold(hash)
        profile.advertise(hash)
        log.log(.info, "lying: advertising photo \(hash.string) as ours")
        try await publishHonestly()
    }

    /// Advertises our own photo again: the store flipped back first, then an edit that publishes it above the lie, then
    /// the bytes released and, with no forge left, the marker removed.
    public func clearAdvertisedPhoto() async throws(Failure) {
        let hash = profile.advertisedPhoto
        profile.advertise(nil)
        log.log(.info, "lying: advertised photo cleared")
        try await publishHonestly()
        if let hash {
            blobs?.release(hash)
        }
        try settleMarker()
    }

    // MARK: pad-profile

    /// Forges our profile at exactly `signedBytes` of `signed` (``ProfileForge``), keeps it as ``paddedProfile`` and
    /// answers it for the caller to send. The marker, naming its clocks, is written before it is answered.
    public func pad(signedBytes: Int) throws(Failure) -> ProfileForge.Forged {
        let now = clock.wallMilliseconds()
        if let forged, now <= max(forged.version, forged.publishedAt) {
            throw .clockNotPastForge(now: now, forged: max(forged.version, forged.publishedAt))
        }
        let made: ProfileForge.Forged
        do {
            made = try ProfileForge.forge(
                signedBytes: signedBytes,
                own: stores.ownProfile.load(),
                custody: stores.custody,
                kept: stores.ownProfile.keptFrame(),
                identity: identity,
                now: now
            )
        } catch {
            log.log(.info, "lying: no padded profile of \(signedBytes) signed bytes: \(error)")
            throw .forge(error)
        }
        let clocks = ForgedClocks(version: made.version, publishedAt: made.publishedAt).merged(with: forged)
        try writeMarker(forged: clocks)
        forged = clocks
        paddedProfile = made
        log.log(.info, "lying: padded profile \(made.id) to \(made.signedBytes) signed bytes")
        return made
    }

    /// Stops sending the forge and publishes an honest profile above every forge of this run, whether a forge is held or
    /// not; with no switch left, the marker goes.
    public func clearPad() async throws(Failure) {
        paddedProfile = nil
        log.log(.info, "lying: padded profile cleared")
        try await publishHonestly()
        try settleMarker()
    }

    // MARK: Start

    /// At a start, after `mesh.start()` and before `ready`: when `stateDirectory` holds a marker, a lie may still be on
    /// air from the last run, so an edit with the current values publishes an honest profile above it, and the marker
    /// goes. Answers whether there was one. Runs with `--lying` or without; with no wrapper, `stores.ownProfile` is honest
    /// already.
    @discardableResult
    public static func recoverAtStart(
        stateDirectory: String, mesh: Mesh, stores: MeshStores, log: any KnitLog = SilentLog()
    ) async throws(Failure) -> Bool {
        let path = markerPath(in: stateDirectory)
        guard let data = FileManager.default.contents(atPath: path) else {
            return false
        }
        // A marker that does not parse still says a lie was set; the edit then outranks whatever the clock allows.
        let clocks = (try? JSONDecoder().decode(Marker.self, from: data))?.forged
        log.log(.info, "lying: a profile lie was left set; publishing an honest profile")
        try await publishHonestly(mesh: mesh, stores: stores, beyond: clocks)
        try removeMarker(at: path)
        return true
    }

    // MARK: Edits and the marker

    private func publishHonestly() async throws(Failure) {
        try await Self.publishHonestly(mesh: mesh, stores: stores, beyond: forged)
        forged = nil
    }

    /// Edits our profile with its current values until it outranks `beyond`, at most ``maxHonestEdits`` times.
    private static func publishHonestly(mesh: Mesh, stores: MeshStores, beyond: ForgedClocks?) async throws(Failure) {
        for _ in 0..<maxHonestEdits {
            let own = stores.ownProfile.load()
            await mesh.updateProfile(name: own.name, status: own.status, openToChat: own.openToChat)
            guard let beyond, !beyond.outranked(by: stores.ownProfile.load()) else {
                return
            }
        }
        let own = stores.ownProfile.load()
        if let beyond {
            throw .honestEditsBelowForge(version: own.version, publishedAt: own.publishedAt, forged: beyond)
        }
    }

    private func writeMarker(forged clocks: ForgedClocks? = nil) throws(Failure) {
        let marker = Marker(forged: clocks ?? forged)
        do {
            let url = URL(fileURLWithPath: markerPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(marker).write(to: url, options: .atomic)
        } catch {
            throw .marker("cannot write \(markerPath): \(error)")
        }
    }

    /// Rewrites the marker for what is still set, or removes it when nothing is.
    private func settleMarker() throws(Failure) {
        if profile.advertisedPhoto != nil || paddedProfile != nil {
            try writeMarker()
        } else {
            try Self.removeMarker(at: markerPath)
        }
    }

    private static func removeMarker(at path: String) throws(Failure) {
        guard FileManager.default.fileExists(atPath: path) else {
            return
        }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            throw .marker("cannot remove \(path): \(error)")
        }
    }

    private static func markerPath(in stateDirectory: String) -> String {
        stateDirectory + "/" + markerName
    }
}
