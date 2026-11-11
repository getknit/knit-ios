#if os(iOS)
    extension AppEnvironment {
        /// Whether the presence keys' per-decision trail is logged: in a debug build alone, since a dated line says when the
        /// user blocked someone (ADR 2026-11.prsp).
        static var logsPresenceKeyTrail: Bool {
            #if DEBUG
                true
            #else
                false
            #endif
        }
    }
#endif
