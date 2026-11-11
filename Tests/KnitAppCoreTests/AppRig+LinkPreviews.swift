import KnitMesh

@testable import KnitAppCore

extension AppRig {
    /// A rig whose session draws link previews' cards, as a debug build's does (ADR 2026-11.hcvg), screening words with
    /// `screening`.
    init(screening: TextScreening? = nil, linkPreviews: LinkPreviews) {
        stores = MeshStores.inMemory()
        mesh = FakeMesh(nodeId: Self.me.nodeId, stores: stores, radio: nil, keys: Self.me.keys)
        notifier = RecordingNotifier()
        session = AppSession(
            identity: OwnIdentity(bundle: Self.me.bundle),
            stores: stores,
            mesh: mesh,
            notifier: notifier,
            textScreening: screening,
            linkPreviews: linkPreviews
        )
    }
}
