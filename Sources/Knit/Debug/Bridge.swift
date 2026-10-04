#if os(iOS) && DEBUG
    import Foundation
    import KnitAppCore
    import KnitBLE
    import KnitControl
    import KnitCrypto
    import KnitMesh
    import KnitStore
    import KnitWire
    import os

    /// A debug build's bridge: `knit-peer`'s control protocol (``MeshControl``) served to every computer connected
    /// (``BridgeListener``), over USB and, on a network pinned over USB, over Wi-Fi (``WiFiGate``), so a script drives
    /// and checks this phone as it does the Linux peer (ADR 2026-09.kwa8). Commands go through the session, so they
    /// show on screen as taps would. Replies go to the connection that asked, and events to every connection. The
    /// bridge answers `wifi`, `wifi-pin` and `wifi-unpin` itself (``WiFiCommand``); `scan-filter`, since only the
    /// iPhone's radio has a scan probe (``ScanProbeCommand``); `storage`, since only the app keeps its identity in the
    /// Keychain and its database under Data Protection (``StorageCommand``); and `photos`, since only the app decodes
    /// them (``PhotosCommand``). Each `status` carries
    /// `memoryAvailableKb`, how much more Knit may take before iOS ends it, so a soak can see its memory grow.
    @MainActor
    internal final class Bridge {
        nonisolated private static let bytesPerKilobyte = 1024

        private let listener: BridgeListener
        private let wifi: WiFiGate

        /// A bridge to `mesh`, driven through `session`, which it also taps for events, to `radio`'s scan probe, to
        /// `storage`, which a demo has none of, and to the photos threads draw.
        init(
            session: AppSession,
            mesh: Mesh,
            radio: BLERadio?,
            bundle: PublicKeyBundle,
            clock: any MeshClock,
            log: any KnitLog,
            version: String,
            storage: StorageReport?,
            photos: BlobImageCache
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
            let gate = WiFiGate(log: log, defaults: .standard)
            let channel = BridgeListener(log: log) {
                control.ready
            } answer: { line, origin in
                if let command = WiFiCommand.parse(line) {
                    return (await gate.answer(command, from: origin), false)
                }
                if let probe = ScanProbeCommand.parse(line) {
                    return (await probe.answer(radio), false)
                }
                if let ask = StorageCommand.parse(line) {
                    return (await ask.answer(storage), false)
                }
                if let ask = PhotosCommand.parse(line) {
                    return (await ask.answer(session, photos: photos), false)
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
            gate.attach(channel)
            listener = channel
            wifi = gate
        }

        /// Listens anew, and on Wi-Fi too if the phone is on a pinned network; called at launch and at every foreground.
        func start() {
            listener.start()
            wifi.refresh()
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

        func postToRoom(_ text: String, photo: OutgoingPhoto?) async -> MessageRecord? {
            await session.send(text, photo: photo, in: Conversations.nearby)
        }

        func sendDirectMessage(_ text: String, to recipient: NodeId, photo: OutgoingPhoto?) async -> MessageRecord? {
            await session.send(text, photo: photo, in: recipient.string)
        }

        func accept(_ conversationId: String) async {
            await session.accept(conversationId)
        }

        func updateProfile(name: String, status: String, openToChat: Bool) async {
            await session.updateProfile(name: name, status: status, openToChat: openToChat)
        }

        func setAvatar(_ jpeg: [UInt8]?) async {
            await session.setAvatar(jpeg)
        }

        func createGroup(with others: [NodeId]) async -> GroupRecord? {
            await session.createGroup(with: others)
        }

        func sendGroupMessage(_ text: String, to groupId: String, photo: OutgoingPhoto?) async -> MessageRecord? {
            await session.send(text, photo: photo, in: groupId)
        }

        func renameGroup(_ groupId: String, to name: String) async -> GroupRecord? {
            await session.renameGroup(groupId, to: name)
        }

        func leaveGroup(_ groupId: String) async -> Bool {
            await session.leaveGroup(groupId)
        }

        func block(_ peer: NodeId) async {
            await session.block(peer)
        }

        func unblock(_ peer: NodeId) async {
            await session.unblock(peer)
        }
    }
#endif
