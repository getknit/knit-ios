#if os(iOS)
    import KnitAppCore
    import KnitCrypto
    import KnitMesh
    // The spool's socket is a debug build's alone until the maintainer approves the plane (ADR 2026-11.adrq):
    // `SpoolNetIsolationTests` holds this import, and the factory's line below, inside `#if DEBUG`.
    #if DEBUG
        import KnitSpoolNet
    #endif

    #if DEBUG
        /// The relay settings the identity replacer voids the consent of, which exist only once the environment it is
        /// composed into does.
        @MainActor
        private final class ConsentHolder {
            weak var relays: InternetRelays?
        }

        extension AppEnvironment {
            /// What opens a relay's socket in a debug build's live launch: one factory per mesh, its marker logged as it is
            /// made, which `scripts/check.sh release` looks for in a store build.
            static func spoolSockets(log: any KnitLog) -> any SpoolSocketFactory {
                // The composition root names the socket; the loading itself stays in KnitSpoolNet.
                // swiftlint:disable:next seam_url_loading
                URLSessionSpoolSocketFactory(log: log)
            }

            /// The live environment from `parts`, dialling relays through a socket factory of its own, with the relay settings
            /// over `preferences` and the Keychain, read now: after the identity, so the preferences answer, since before the
            /// first unlock they can read back empty and must never seed the house relay again or overwrite the switch.
            /// Replacing the identity, Diagnostics' one way to, first voids the relay consent in the kept list and deletes its
            /// nonce (``InternetRelays/forgetConsent()``), then replaces the identity: no consent outlives the identity it was
            /// given beside, whatever the Keychain's delete does, and a replacement that fails costs only a switch that asks
            /// again.
            static func liveWithRelays(
                _ parts: Parts, ratchet: Bool, preferences: any AppPreferences, replace: @escaping IdentityReplacer
            ) -> AppEnvironment {
                let secrets = KeychainRelayStore(log: parts.log)
                let consent = ConsentHolder()
                var dialling = parts
                dialling.spoolSockets = spoolSockets(log: parts.log)
                let environment = compose(dialling, ratchet: ratchet) { keys in
                    consent.relays?.forgetConsent()
                    try replace(keys)
                }
                environment.startRelays(preferences: preferences, secrets: secrets, log: parts.log)
                consent.relays = environment.relays
                return environment
            }

            /// The demo from `parts`, with relay settings in memory over ``DemoRelays``, which opens no socket, when `relays`
            /// (`-demoRelays`): a UI test walks the settings and reaches no relay.
            static func demoWithRelays(_ parts: Parts, relays: Bool) -> AppEnvironment {
                var demo = parts
                demo.demoRelays = relays
                let environment = compose(demo, ratchet: false, replace: nil) // A demo keeps no prekeys and reaches no one.
                if relays {
                    environment.startRelays(preferences: MemoryPreferences(), secrets: MemoryRelaySecrets(), log: parts.log)
                }
                return environment
            }

            /// Makes the relay settings over this environment's stream into the mesh and reads the list, which tells the mesh
            /// what to carry: the live launch's, once the identity was read, or the demo's under `-demoRelays`. The build flag
            /// it is given is the compile-time one.
            func startRelays(preferences: any AppPreferences, secrets: any RelaySecretStore, log: any KnitLog) {
                // `scripts/check.sh release` fails when a release build holds this line: it would mean the relay settings ship.
                log.log(.info, "internet relays are on in this debug build")
                let made = InternetRelays(debugBuild: true, preferences: preferences, secrets: secrets, phases: phases, log: log)
                made.load()
                relays = made
            }
        }
    #endif
#endif
