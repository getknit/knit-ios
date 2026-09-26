#if os(Linux)
    import Glibc
    import KnitMesh
    import KnitWire

    /// Everything the radio does, on one thread: a `poll` loop over the mailbox, the D-Bus connection, the L2CAP
    /// listener and every channel. Nothing here blocks except `poll` itself, and nothing here is shared: callers reach
    /// it only through the ``Mailbox``, and it reports only through `emit`.
    ///
    /// The tests drive one by hand with ``iterate(maximumWaitMilliseconds:)``, against a fake BlueZ and Unix sockets.
    internal final class BlueZLoop {
        /// What the loop needs to run.
        struct Configuration: Sendable {
            var bus: BusConnection.Address
            var adapter: AdapterSelection
            var profile: RadioProfile
            var sockets: any SocketProvider
            /// Where this process's own D-Bus objects live: the advertisements and the GATT application.
            var objectRoot: String
            var log: any KnitLog
            /// How long after a peer dials us the advert is registered again. The kernel stops a connectable
            /// advertising instance when a peer connects through it (spike (e)), and this brings it back.
            var readvertiseDelayMilliseconds: Int64 = 1000
            /// How long to wait before retrying a failed advert registration, or a bus that could not be reached.
            var retryDelayMilliseconds: Int64 = 5000
        }

        /// A channel's socket and what waits to be written to it.
        struct Channel {
            let descriptor: Int32
            var connecting: Bool
            /// The largest single write, known once the channel is open.
            var limit = 0
            var outbox: [[UInt8]] = []
            /// How much of the outbox's first entry is already written.
            var written = 0
            var queuedBytes = 0
        }

        private enum Polled {
            case mailbox
            case bus
            case listener
            case channel(ChannelID)
        }

        /// A peer that stops reading must not grow our memory without bound: past this much queued, its channel
        /// closes. Four MiB is several hundred frames, far more than a healthy link ever queues.
        static let maximumQueuedBytes = 4 << 20
        static let readBufferSize = 65_536
        /// How many SDUs one channel may deliver per turn of the loop, so a busy one cannot starve the rest.
        static let readsPerTurn = 64
        /// How long one turn waits when nothing is due.
        static let idleWaitMilliseconds: Int32 = 1000
        /// How long shutdown waits for BlueZ to hear our withdrawals, and how long each wait for the bus lasts.
        static let shutdownGraceMilliseconds: Int64 = 500
        static let shutdownPollMilliseconds: Int32 = 50

        let configuration: Configuration
        let mailbox: Mailbox
        let emit: (RadioEvent) -> Void
        var log: any KnitLog { configuration.log }

        var bus: BusConnection?
        /// BlueZ's unique name on the system bus, once known; only it may call this process's objects.
        var bluezOwner: String?
        var reconnectAt: Int64?
        /// The radio was asked to run.
        var wanted = false
        /// The adapter is present, with the expected address.
        var adapterPresent = false
        var adapterRefused = false
        var powered = false
        /// Listening, scanning and advertising.
        var isUp = false
        var reportedState: RadioState?
        var devices: [String: BlueZDevice] = [:]

        var desiredAdvert: AdvertPayload?
        var activeAdvert: (path: String, payload: AdvertPayload)?
        var pendingAdvert: (path: String, payload: AdvertPayload)?
        var advertGeneration = 0
        var refreshAdvertAt: Int64?
        var gattRegistered = false
        /// Discovery was started and not yet stopped.
        var scanning = false

        var listener: ListeningSocket?
        var channels: [ChannelID: Channel] = [:]
        var readBuffer = [UInt8](repeating: 0, count: readBufferSize)
        private(set) var isFinished = false

        init(configuration: Configuration, mailbox: Mailbox, emit: @escaping (RadioEvent) -> Void) {
            self.configuration = configuration
            self.mailbox = mailbox
            self.emit = emit
        }

        // MARK: Running

        /// Connects, then turns until shut down.
        func run() {
            connect(now: Monotonic.milliseconds())
            while !isFinished {
                iterate(maximumWaitMilliseconds: Self.idleWaitMilliseconds)
            }
        }

        /// One turn: waits for something to be ready, at most until the next deadline, then serves it.
        func iterate(maximumWaitMilliseconds: Int32) {
            var polled: [Polled] = [.mailbox]
            var descriptors = [pollfd(fd: mailbox.descriptor, events: Int16(POLLIN), revents: 0)]
            if let bus, let descriptor = bus.fileDescriptor {
                polled.append(.bus)
                descriptors.append(pollfd(fd: descriptor, events: Int16(POLLIN) | (bus.wantsToWrite ? Int16(POLLOUT) : 0), revents: 0))
            }
            if let listener {
                polled.append(.listener)
                descriptors.append(pollfd(fd: listener.descriptor, events: Int16(POLLIN), revents: 0))
            }
            for (id, channel) in channels.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                let writing = channel.connecting || !channel.outbox.isEmpty
                polled.append(.channel(id))
                descriptors.append(pollfd(fd: channel.descriptor, events: Int16(POLLIN) | (writing ? Int16(POLLOUT) : 0), revents: 0))
            }
            _ = poll(&descriptors, nfds_t(descriptors.count), wait(atMost: maximumWaitMilliseconds, now: Monotonic.milliseconds()))

            let now = Monotonic.milliseconds()
            for (index, kind) in polled.enumerated() where descriptors[index].revents != 0 {
                switch kind {
                case .mailbox, .bus:
                    continue
                case .listener:
                    acceptAll(now: now)
                case .channel(let id):
                    service(id, events: descriptors[index].revents)
                }
            }
            for command in mailbox.take() {
                perform(command, now: now)
            }
            bus?.pump(now: now)
            fireTimers(now: now)
            bus?.pump(now: now)
        }

        private func wait(atMost limit: Int32, now: Int64) -> Int32 {
            let deadlines = [bus?.nextDeadline, pendingAdvert == nil ? refreshAdvertAt : nil, reconnectAt].compactMap(\.self)
            guard let next = deadlines.min() else {
                return limit
            }
            return Int32(clamping: max(0, min(Int64(limit), next - now)))
        }

        private func fireTimers(now: Int64) {
            if let due = reconnectAt, now >= due {
                reconnectAt = nil
                connect(now: now)
            }
            if let due = refreshAdvertAt, now >= due, pendingAdvert == nil {
                syncAdvert(now: now)
            }
        }

        // MARK: Commands

        func perform(_ command: RadioCommand, now: Int64) {
            switch command {
            case .start:
                wanted = true
                if bus == nil, reconnectAt == nil {
                    connect(now: now)
                }
                reconcile(now: now)
            case .stop:
                wanted = false
                reconcile(now: now)
            case .advertise(let payload):
                desiredAdvert = payload
                syncAdvert(now: now)
            case .dial(let id, let address, let psm):
                dial(id, address: address, psm: psm)
            case .write(let id, let bytes):
                enqueue(bytes, on: id)
            case .close(let id):
                closeChannel(id)
            case .shutdown:
                shutdown(now: now)
            }
        }

        /// Brings the plane up or down to match what was asked and what the adapter allows.
        func reconcile(now: Int64) {
            let usable = adapterPresent && !adapterRefused && bus?.isOpen == true
            if wanted, usable, powered {
                if !isUp {
                    bringUp(now: now)
                }
            } else if isUp {
                bringDown()
            }
            if wanted, usable, !powered {
                report(.off)
            }
        }

        func report(_ state: RadioState) {
            guard reportedState != state else {
                return
            }
            reportedState = state
            log.log(.info, "bluez radio \(state)")
            emit(.state(state))
        }

        private func bringUp(now: Int64) {
            if listener == nil {
                do {
                    listener = try configuration.sockets.listen()
                } catch {
                    log.log(.warning, "bluez could not listen: \(error.call) failed with errno \(error.code)")
                    report(.off)
                    return
                }
            }
            guard let listener else {
                return
            }
            isUp = true
            report(.on)
            emit(.listening(psm: listener.psm))
            startDiscovery(now: now)
            if configuration.profile == .ios {
                registerApplication(now: now)
            }
        }

        /// Stops advertising, scanning and listening, and closes every channel. The link manager has forgotten the
        /// channels already, or does when it hears the radio went off, so no `closed` event follows.
        func bringDown() {
            isUp = false
            let now = Monotonic.milliseconds()
            withdrawAdvertisements(now: now)
            withdrawApplication(now: now)
            stopDiscovery(now: now)
            for (_, channel) in channels {
                Descriptor.close(channel.descriptor)
            }
            channels.removeAll()
            if let listener {
                Descriptor.close(listener.descriptor)
            }
            listener = nil
            desiredAdvert = nil
            refreshAdvertAt = nil
        }

        private func shutdown(now: Int64) {
            wanted = false
            reconcile(now: now)
            // Let the withdrawals reach BlueZ before the connection goes; BlueZ also drops everything of ours once
            // it sees the connection close, so this is courtesy rather than cleanup.
            let deadline = now + Self.shutdownGraceMilliseconds
            while let bus, bus.isOpen, bus.nextDeadline != nil || bus.wantsToWrite, Monotonic.milliseconds() < deadline {
                var descriptor = pollfd(fd: bus.fileDescriptor ?? -1, events: Int16(POLLIN) | Int16(POLLOUT), revents: 0)
                _ = poll(&descriptor, 1, Self.shutdownPollMilliseconds)
                bus.pump(now: Monotonic.milliseconds())
            }
            bus?.close()
            bus = nil
            isFinished = true
        }
    }
#endif
