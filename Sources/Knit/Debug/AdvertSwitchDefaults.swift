#if os(iOS) && DEBUG
    import Foundation
    import KnitAppCore
    import KnitBLE
    import KnitControl
    import KnitMesh

    /// The app's side of the bridge's `advert` (``AdvertHost``; ADR 2026-11.prsp, "The bridge and the harness"): the switch
    /// kept in the defaults under the key `-blind` keeps it under (``AppEnvironment/blindSwitchKey``), so the next launch,
    /// iOS's own among them, starts where the bridge left it, and the CoreBluetooth server read on its queue
    /// (``BLERadio/servingReport()``), which `advert blind` waits on before it says `applied`.
    internal struct AdvertSwitchDefaults: AdvertHost {
        /// The links' gate: open in a live debug launch, shut in the demo, whose radio goes nowhere.
        let build: Bool
        /// The radio, which a demo has none of.
        let radio: BLERadio?

        var defaultSwitch: Bool { LaunchOptions.blindDefault }

        /// The word `-blind` keeps, `on` or `off`, read as the bridge's switch; anything else is nothing stored.
        func stored() -> AdvertSwitchChange {
            let word = UserDefaults.standard.string(forKey: AppEnvironment.blindSwitchKey)
            return word.flatMap(LaunchOptions.Choice.init(word:)).map { $0 == .on ? .on : .off } ?? .clear
        }

        /// Kept as `-blind` keeps its word, so the next launch reads it; `clear` forgets it.
        func store(_ change: AdvertSwitchChange) {
            guard change != .clear else {
                UserDefaults.standard.removeObject(forKey: AppEnvironment.blindSwitchKey)
                return
            }
            UserDefaults.standard.set((change == .on ? LaunchOptions.Choice.on : .off).word, forKey: AppEnvironment.blindSwitchKey)
        }

        func serving() async -> GattServingReport? {
            await radio?.servingReport()
        }
    }
#endif
