#if os(iOS)
    import KnitAppCore
    import KnitCrypto
    import KnitMesh
    import KnitWire
    import UIKit

    extension AppEnvironment {
        /// The mesh `parts` make, on `clock`, with the ratchet's switch and link previews' as they say. Only a debug build's
        /// live launch hands it a relay socket factory, and every mesh starts with its spool paused, so only the scene's own
        /// `.active` runs relays (ADR 2026-11.adrq, P6).
        static func mesh(_ parts: Parts, ratchet: Bool, linkPreviews: Bool, clock: SystemClock) -> Mesh {
            Mesh(
                identity: parts.identity,
                prekeys: parts.prekeys,
                deviceTag: parts.isSample ? nil : DeviceTag.derive(UIDevice.current.identifierForVendor?.uuidString),
                stores: parts.stores,
                radio: parts.radio,
                clock: clock,
                random: SystemRandomNumberGenerator(),
                // Every build queries a blob's holders before it asks, as Android's does since its `BLOB_QUERY` shipped
                // on in release (knit-next `713b29d6`, ADR 2026-10.m9uq's amendment); the ratchet too, unless a debug `-ratchet off`.
                // A quote rebuilt from its original names a GIF, a file or a voice note as the composer does
                // (knit-next ADR 2026-10.gpa3).
                // Our presence keys go to our contacts in every build, their dated trail logged in debug alone (ADR 2026-11.prsp).
                configuration: MeshConfiguration(
                    queriesBlobHolders: true,
                    ratchet: ratchet,
                    linkPreviews: linkPreviews,
                    sendsOwnPresenceKeys: true,
                    logsPresenceKeyTrail: logsPresenceKeyTrail
                ) { attachment in
                    AttachmentKind.quoteLabel(of: attachment)
                },
                linkConfiguration: parts.links,
                log: parts.log,
                partials: parts.partials,
                spoolSockets: parts.spoolSockets,
                // Every launch starts with the spool paused: only the scene's own `.active` resumes it (ADR 2026-11.adrq, P6).
                spoolStartsPaused: true
            )
        }

        /// The app's session over `service`, which reads words with the text classifier and photos' sizes with ImageIO,
        /// and in a debug build records, plays and reads voice notes, and draws link previews' cards with `linkPreviews`.
        static func session(
            _ parts: Parts, over service: any MeshService, notifying alerts: LocalNotifier?, linkPreviews: LinkPreviews?
        ) -> AppSession {
            let clock = SystemClock()
            let now: @Sendable () -> Int64 = { clock.wallMilliseconds() }
            return AppSession(
                identity: OwnIdentity(bundle: parts.identity.bundle),
                stores: parts.stores,
                mesh: service,
                notifier: alerts,
                textScreening: .bundled(classifier: parts.textClassifier, log: parts.log),
                names: .bundled(log: parts.log),
                photoDimensions: { PhotoDecoder.dimensions($0) },
                voiceNotes: voiceNotes(log: parts.log, demoClip: parts.demoVoice),
                linkPreviews: linkPreviews,
                preferences: parts.preferences,
                now: now
            )
        }
    }
#endif
