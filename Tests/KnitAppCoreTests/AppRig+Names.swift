import KnitMesh

@testable import KnitAppCore

extension AppRig {
    /// A rig whose session screens names with `names` (knit-next ADR 2026-11.y4pc), keeping its toggle in `preferences`.
    init(names: ShownNames, preferences: MemoryPreferences = MemoryPreferences()) {
        stores = MeshStores.inMemory()
        mesh = FakeMesh(nodeId: Self.me.nodeId, stores: stores, radio: nil, keys: Self.me.keys)
        notifier = RecordingNotifier()
        session = AppSession(
            identity: OwnIdentity(bundle: Self.me.bundle),
            stores: stores,
            mesh: mesh,
            notifier: notifier,
            names: names,
            preferences: preferences
        )
    }
}
