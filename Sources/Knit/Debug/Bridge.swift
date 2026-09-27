#if os(iOS) && DEBUG
    import KnitAppCore
    import KnitControl
    import KnitCrypto
    import KnitMesh
    import KnitStore
    import KnitWire

    /// A debug build's bridge: `knit-peer`'s control protocol (``MeshControl``) served over USB to every computer
    /// connected (``BridgeListener``), so a script drives and checks this phone as it does the Linux peer
    /// (ADR 2026-09.kwa8). Commands go through the session, so they show on screen as taps would. Replies go to the
    /// connection that asked, and events to every connection.
    @MainActor
    internal final class Bridge {
        private let listener: BridgeListener

        /// A bridge to `mesh`, driven through `session`, which it also taps for events.
        init(session: AppSession, mesh: Mesh, bundle: PublicKeyBundle, clock: any MeshClock, log: any KnitLog, version: String) {
            let control = MeshControl(
                bundle: bundle,
                mesh: mesh,
                actions: SessionActions(session: session),
                stores: session.stores,
                clock: clock,
                details: ["radioProfile": "ios", "host": "app", "version": .string(version)]
            )
            let channel = BridgeListener(log: log) {
                control.ready
            } answer: { line in
                let reply = await control.handle(line)
                return (reply.line, reply.quits)
            }
            let (events, continuation) = AsyncStream<MeshEvent>.makeStream()
            session.eventTap = { continuation.yield($0) }
            Task {
                for await event in events {
                    for line in await control.report(event) {
                        channel.broadcast(line)
                    }
                }
            }
            listener = channel
        }

        /// Listens, unless it already does; called at launch and at every foreground.
        func start() {
            listener.start()
        }
    }

    /// The session's actions, so a command takes the path a tap takes.
    private struct SessionActions: ControlActions {
        let session: AppSession

        func start() async {
            await session.start()
        }

        func stop() async {
            await session.stop()
        }

        func postToRoom(_ text: String) async -> MessageRecord? {
            await session.send(text, in: Conversations.nearby)
        }

        func sendDirectMessage(_ text: String, to recipient: NodeId) async -> MessageRecord? {
            await session.send(text, in: recipient.string)
        }

        func accept(_ conversationId: String) async {
            await session.accept(conversationId)
        }

        func updateProfile(name: String, status: String, openToChat: Bool) async {
            await session.updateProfile(name: name, status: status, openToChat: openToChat)
        }
    }
#endif
