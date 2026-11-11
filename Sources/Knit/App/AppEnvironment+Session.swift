#if os(iOS)
    import KnitAppCore
    import KnitCrypto
    import KnitMesh

    extension AppEnvironment {
        /// The app's session over `service`, which reads words with the text classifier and photos' sizes with ImageIO,
        /// and in a debug build records, plays and reads voice notes, and draws link previews' cards with `linkPreviews`.
        static func session(
            _ parts: Parts, over service: any MeshService, notifying alerts: LocalNotifier?, linkPreviews: LinkPreviews?
        ) -> AppSession {
            AppSession(
                identity: OwnIdentity(bundle: parts.identity.bundle),
                stores: parts.stores,
                mesh: service,
                notifier: alerts,
                textScreening: .bundled(classifier: parts.textClassifier, log: parts.log),
                photoDimensions: { PhotoDecoder.dimensions($0) },
                voiceNotes: voiceNotes(log: parts.log, demoClip: parts.demoVoice),
                linkPreviews: linkPreviews,
                preferences: parts.preferences
            )
        }
    }
#endif
