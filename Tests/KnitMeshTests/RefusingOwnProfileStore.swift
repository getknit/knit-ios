import KnitStore
import KnitWire

@testable import KnitMesh

/// What the own-profile-frame suites read of an engine (ADR 2026-11.xfcq): our current stamp's id, custody's row for it,
/// and the kept frame.
extension EngineFixture {
    /// Our profile's id under the stamp the store reads now.
    var ownProfileId: String {
        FrameId.profileId(sender: me.nodeId.string, publishedAt: stores.ownProfile.load().publishedAt)
    }

    /// Custody's live row for our current stamp, as a re-serve sends it.
    var ownRow: WireEnvelope? {
        stores.custody.frame(ownProfileId, now: clock.wallMilliseconds())?.reserved
    }

    /// The frame our profile store keeps, or `nil` for none or a failed read.
    var keptFrame: WireEnvelope? {
        guard case .kept(let wire) = stores.ownProfile.keptFrame() else {
            return nil
        }
        return wire
    }

    /// Every frame this engine wrote under `id`, to anyone.
    func writes(of id: String) -> [WireEnvelope] {
        transport.written.filter { ExactKey($0.envelope.id) == ExactKey(id) }.map(\.wire)
    }
}

extension WireEnvelope {
    /// Whether `other` is the same signature over the same bytes, whatever the routing counters say.
    func sameBytes(as other: WireEnvelope?) -> Bool {
        sig == other?.sig && signed == other?.signed
    }
}

/// An own-profile store over memory whose kept-frame read can fail and whose kept-frame write can be refused, as a
/// database that cannot read or write its file: a failing read fails the open unit and answers
/// ``KeptProfileFrame/unreadable``, and a refused write answers `false`. Everything else goes to the memory store, which
/// the unit checkpoints.
final class RefusingOwnProfileStore: OwnProfileStore, Checkpointing, @unchecked Sendable {
    let held: MemoryOwnProfileStore
    /// The unit a failing read fails. Set once the stores are bundled, before the engine runs.
    var transactor: MemoryTransactor?
    /// Whether the kept frame's read fails. Read on the engine's one thread only, as the stores are.
    var failsKeptReads = false
    /// Whether the kept frame's write is refused.
    var refusesKeeps = false
    /// Whether a profile's save is refused, the row read as it was.
    var refusesSaves = false
    /// Whether the profile's row fails to read: ``loadIfReadable()`` answers `nil` and ``load()`` a fresh profile, as
    /// `SQLOwnProfileStore` falls back.
    var failsLoads = false
    /// Every kept-frame write asked for, landed or refused, oldest first: `nil` is a forget.
    private(set) var keeps: [WireEnvelope?] = []

    init(_ profile: OwnProfile = OwnProfile()) {
        held = MemoryOwnProfileStore(profile)
    }

    func load() -> OwnProfile { failsLoads ? OwnProfile() : held.load() }
    func loadIfReadable() -> OwnProfile? { failsLoads ? nil : held.loadIfReadable() }
    func save(_ profile: OwnProfile) {
        if !refusesSaves {
            held.save(profile)
        }
    }

    func keptFrame() -> KeptProfileFrame {
        guard !failsKeptReads else {
            transactor?.failCurrentUnit()
            return .unreadable
        }
        return held.keptFrame()
    }

    @discardableResult
    func keep(_ frame: WireEnvelope?) -> Bool {
        keeps.append(frame)
        guard !refusesKeeps else {
            transactor?.failCurrentUnit()
            return false
        }
        return held.keep(frame)
    }

    func checkpoint() -> StoreCheckpoint { held.checkpoint() }
}

extension MeshStores {
    /// Stores in memory around a ``RefusingOwnProfileStore``, wired to fail the unit its reads run in.
    static func refusingOwnProfile() -> (stores: Self, profiles: RefusingOwnProfileStore) {
        let profiles = RefusingOwnProfileStore()
        let stores = Self.inMemory(ownProfileStore: profiles)
        profiles.transactor = stores.transactor as? MemoryTransactor
        return (stores, profiles)
    }
}
