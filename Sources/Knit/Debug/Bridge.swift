#if os(iOS) && DEBUG
    import KnitAppCore
    import KnitBLE
    import KnitControl
    import KnitCrypto
    import KnitMesh
    import KnitStore
    import KnitWire
    import os

    /// A debug build's bridge: `knit-peer`'s control protocol (``MeshControl``) served over USB to every computer
    /// connected (``BridgeListener``), so a script drives and checks this phone as it does the Linux peer
    /// (ADR 2026-09.kwa8). Commands go through the session, so they show on screen as taps would. Replies go to the
    /// connection that asked, and events to every connection. The bridge answers `scan-filter` itself, since only
    /// the iPhone's radio has a scan probe (``ScanProbeCommand``), and `storage`, since only the app keeps its identity
    /// in the Keychain and its database under Data Protection (``StorageCommand``). Each `status` carries
    /// `memoryAvailableKb`, how much more Knit may take before iOS ends it, so a soak can see its memory grow.
    @MainActor
    internal final class Bridge {
        nonisolated private static let bytesPerKilobyte = 1024

        private let listener: BridgeListener

        /// A bridge to `mesh`, driven through `session`, which it also taps for events, to `radio`'s scan probe, and to
        /// `storage`, which a demo has none of.
        init(
            session: AppSession,
            mesh: Mesh,
            radio: BLERadio?,
            bundle: PublicKeyBundle,
            clock: any MeshClock,
            log: any KnitLog,
            version: String,
            storage: StorageReport?
        ) {
            let control = MeshControl(
                bundle: bundle,
                mesh: mesh,
                actions: SessionActions(session: session),
                stores: session.stores,
                clock: clock,
                details: ["radioProfile": "ios", "host": "app", "version": .string(version)]
            ) {
                ["memoryAvailableKb": .int(Int64(os_proc_available_memory() / Self.bytesPerKilobyte))]
            }
            let channel = BridgeListener(log: log) {
                control.ready
            } answer: { line in
                if let probe = ScanProbeCommand.parse(line) {
                    return (await probe.answer(radio), false)
                }
                if let ask = StorageCommand.parse(line) {
                    return (await ask.answer(storage), false)
                }
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

        func createGroup(with others: [NodeId]) async -> GroupRecord? {
            await session.createGroup(with: others)
        }

        func sendGroupMessage(_ text: String, to groupId: String) async -> MessageRecord? {
            await session.send(text, in: groupId)
        }

        func renameGroup(_ groupId: String, to name: String) async -> GroupRecord? {
            await session.renameGroup(groupId, to: name)
        }

        func leaveGroup(_ groupId: String) async -> Bool {
            await session.leaveGroup(groupId)
        }
    }
#endif
