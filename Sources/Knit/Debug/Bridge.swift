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
    /// Keychain and its database under Data Protection (``StorageCommand``); `photos`, since only the app decodes them
    /// (``PhotosCommand``); `screen`, since only the app runs the content filter's model (``ScreenCommand``); and the
    /// `record-` commands, since only the app has ReplayKit (``RecordCommand``, ADR 2026-10.x2cq). Each `status` carries
    /// `memoryAvailableKb`, how much more Knit may take before iOS ends it, so a soak can see its memory grow.
    @MainActor
    internal final class Bridge {
        nonisolated private static let bytesPerKilobyte = 1024

        private let listener: BridgeListener
        private let wifi: WiFiGate

        /// A bridge to `mesh`, driven through `session`, which it also taps for events, to `radio`'s scan probe, to
        /// `storage`, which a demo has none of, to the photos threads draw and what `screening` hides of them, and to the
        /// filter's `classifier` and `textClassifier`.
        init(
            session: AppSession,
            mesh: Mesh,
            radio: BLERadio?,
            bundle: PublicKeyBundle,
            clock: any MeshClock,
            log: any KnitLog,
            version: String,
            storage: StorageReport?,
            photos: BlobImageCache,
            screening: PhotoScreening,
            classifier: any PhotoClassifier,
            textClassifier: any TextClassifier
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
            let takes = BridgeRecorder.start(clock: clock)
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
                    return (await ask.answer(session, photos: photos, screening: screening), false)
                }
                if let ask = ScreenCommand.parse(line) {
                    return (await ask.answer(classifier), false)
                }
                if let ask = ScreenTextCommand.parse(line) {
                    return (await ask.answer(textClassifier), false)
                }
                if let ask = RecordCommand.parse(line) {
                    return (await ask.answer(takes), false)
                }
                let reply = await control.handle(line)
                return (reply.line, reply.quits)
            }
            Self.relay(session, through: control, to: channel)
            gate.attach(channel)
            listener = channel
            wifi = gate
        }

        /// Sends every event `session` taps to every connection on `channel`, as `control` writes it.
        private static func relay(_ session: AppSession, through control: MeshControl, to channel: BridgeListener) {
            let (events, continuation) = AsyncStream<MeshEvent>.makeStream()
            session.eventTap = { continuation.yield($0) }
            Task {
                for await event in events {
                    for line in await control.report(event) {
                        channel.broadcast(line)
                    }
                }
            }
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

        func postToRoom(
            _ text: String, photo: OutgoingPhoto?, replyTo: MessageReply?, mentions: [MessageMention]
        ) async -> MessageRecord? {
            await session.send(text, photo: photo, replyTo: replyTo, mentions: mentions, in: Conversations.nearby)
        }

        func sendDirectMessage(
            _ text: String, to recipient: NodeId, photo: OutgoingPhoto?, replyTo: MessageReply?, mentions: [MessageMention]
        ) async -> MessageRecord? {
            await session.send(text, photo: photo, replyTo: replyTo, mentions: mentions, in: recipient.string)
        }

        func heldPhoto(picked: [UInt8]) async -> OutgoingPhoto? {
            await session.heldPhoto(picked: Data(picked))
        }

        /// The quote the composer would write, so a command's reply reads as a tap's (ADR 2026-10.mn29).
        func quote(of messageId: String) async -> MessageReply? {
            await session.quote(of: messageId)
        }

        /// The mention the composer would write, under this phone's label (ADR 2026-10.nbhj).
        func mention(of person: NodeId) async -> MessageMention? {
            await session.mention(of: person)
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

        func sendGroupMessage(
            _ text: String, to groupId: String, photo: OutgoingPhoto?, replyTo: MessageReply?, mentions: [MessageMention]
        ) async -> MessageRecord? {
            await session.send(text, photo: photo, replyTo: replyTo, mentions: mentions, in: groupId)
        }

        func renameGroup(_ groupId: String, to name: String) async -> GroupRecord? {
            await session.renameGroup(groupId, to: name)
        }

        func leaveGroup(_ groupId: String) async -> Bool {
            await session.leaveGroup(groupId)
        }

        func deleteMessage(_ id: String) async -> Bool {
            await session.deleteMessage(id)
        }

        func deleteChat(_ conversationId: String) async -> Bool {
            await session.deleteChat(conversationId)
        }

        /// Reacts as the bubble's menu does, then reads back what the store holds for us.
        func react(to messageId: String, with emoji: String) async -> ReactionRecord? {
            guard await session.react(to: messageId, with: emoji) else {
                return nil
            }
            return await session.stores.messages.reaction(on: messageId, by: session.identity.nodeId)
        }

        /// Tells the thread we are typing, as a keystroke in its composer does.
        func noteTyping(in thread: String) async -> Bool {
            await session.noteTyping(in: thread)
        }

        func block(_ peer: NodeId) async {
            await session.block(peer)
        }

        func unblock(_ peer: NodeId) async {
            await session.unblock(peer)
        }
    }
#endif
