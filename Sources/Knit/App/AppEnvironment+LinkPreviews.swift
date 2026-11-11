#if os(iOS)
    import KnitAppCore
    import KnitMesh

    extension AppEnvironment {
        /// Link previews, a debug build's alone until the maintainer approves them for the store (ADR 2026-11.hcvg). A
        /// release build has none: it draws no card, and its signed profile never claims `CAP_LINK_PREVIEW`, so no Android
        /// phone attaches one to a DM or a group toward it.
        static func linkPreviews(log: any KnitLog) -> LinkPreviews? {
            #if DEBUG
                // `scripts/check.sh release` fails when a release build holds this line: it would mean link previews ship.
                log.log(.info, "link previews are on in this debug build")
                return LinkPreviews()
            #else
                return nil
            #endif
        }
    }
#endif
