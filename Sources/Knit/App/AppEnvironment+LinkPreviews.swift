#if os(iOS)
    import KnitAppCore
    import KnitMesh

    extension AppEnvironment {
        /// Link previews, a debug build's alone until the maintainer approves them for the store (ADR 2026-11.hcvg). A
        /// release build has none: it draws no card, fetches none, shows no setting, and its signed profile never claims
        /// `CAP_LINK_PREVIEW`, so no Android phone attaches one to a DM or a group toward it.
        static func linkPreviews(log: any KnitLog) -> LinkPreviews? {
            #if DEBUG
                // `scripts/check.sh release` fails when a release build holds this line: it would mean link previews ship.
                log.log(.info, "link previews are on in this debug build")
                let gate = PathInternetGate()
                let clock = SystemClock()
                let service = LinkPreviewService(
                    gate: gate,
                    fetcher: PreviewWalk(transport: URLSessionTransport(), resolver: DarwinHostResolver()),
                    shrink: { await CardPictureMaker.shrink($0) },
                    charsets: { CoreCharsets.decode($0, $1) },
                    now: { clock.wallMilliseconds() },
                    sleep: { try await Task.sleep(for: $0) },
                    // The host alone, never the address: a log line can be shared.
                    log: { log.log(.info, "link preview: \($0)") }
                )
                return LinkPreviews(service: service, gate: gate)
            #else
                return nil
            #endif
        }
    }
#endif
