#if os(iOS)
    import KnitAppCore
    import KnitMesh

    extension AppEnvironment {
        /// The blinded advert's two settings at construction (ADR 2026-11.prsp, "Two gates"): the build gate, which only a
        /// debug build opens, and the runtime switch, which sets the writer's state and the radio's expectation of the doorbell's
        /// own service at a cold launch. The switch never sets the gate, so a process started with it off can still be turned
        /// on from the bridge's `advert`.
        struct BlindAdvert {
            /// ``LinkManager/Configuration/blindsAdvert``.
            let gate: Bool
            /// ``LinkManager/Configuration/blindSwitchOn``, and `BLERadio(expectsBlinding:)`.
            let switchOn: Bool

            /// The links' configuration with these settings.
            var links: LinkManager.Configuration {
                LinkManager.Configuration(blindsAdvert: gate, blindSwitchOn: switchOn)
            }
        }

        /// The settings `options` ask for: a debug build opens the gate, its switch where `-blind`, the bridge or the default
        /// left it. A release build passes the gate shut and the switch off, and reads no launch flag and no defaults key.
        static func blindAdvert(_ options: LaunchOptions, log: any KnitLog) -> BlindAdvert {
            #if DEBUG
                // `scripts/check.sh release` fails when a release build holds this line: it would mean the writer's switch
                // ships. Logged from the branch that also sets the radio's expectation, so the two cannot part.
                log.log(.info, "the blinded advert writer is on in this debug build, its switch \(options.blind ? "on" : "off")")
                return BlindAdvert(gate: true, switchOn: options.blind)
            #else
                return BlindAdvert(gate: false, switchOn: false)
            #endif
        }

        #if DEBUG
            /// Where a debug build keeps the switch, `on` or `off`: `-blind`'s choice and the bridge's `advert blind`. Absent,
            /// the default stands (``LaunchOptions/blindDefault``). `scripts/check.sh release` fails when a release build holds
            /// this key.
            nonisolated static let blindSwitchKey = "debug.launch.blind"
        #endif
    }
#endif
