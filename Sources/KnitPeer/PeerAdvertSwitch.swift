public import KnitControl
public import KnitMesh

/// knit-peer's side of `advert` (``AdvertHost``; ADR 2026-11.prsp): the gate as its links were configured, which `main` always
/// opens, the runtime switch kept in memory for the run, its default `--blind`, and no GATT server to report: BlueZ answers
/// each read with the advert of the moment, so a rotation moves no handle there.
public actor PeerAdvertSwitch: AdvertHost {
    nonisolated public let build: Bool
    nonisolated public let defaultSwitch: Bool
    private var value = AdvertSwitchChange.clear

    /// A switch for links whose gate is `build`, `defaultSwitch` until a command stores one.
    public init(build: Bool, defaultSwitch: Bool) {
        self.build = build
        self.defaultSwitch = defaultSwitch
    }

    public func stored() -> AdvertSwitchChange {
        value
    }

    public func store(_ change: AdvertSwitchChange) {
        value = change
    }

    public func serving() -> GattServingReport? {
        nil
    }
}
