#if os(Linux)
    import Glibc
    import KnitCrypto
    import KnitMesh
    import KnitWire
    import KnitSync

    /// What the radio's callers ask of its thread.
    internal enum RadioCommand: Sendable {
        case start
        case stop
        case advertise(AdvertPayload)
        case dial(ChannelID, RadioAddress, psm: UInt16)
        case write(ChannelID, [UInt8])
        case writeDigest(ChannelID, [UInt8])
        case writeFileRecord(ChannelID, [UInt8])
        /// Our `KEY_SHARE`, and a responder's sealer with it (``Radio/writeKeyShare(_:sealer:to:)``).
        case writeKeyShare(ChannelID, [UInt8], LinkSealer?)
        /// A dialer's sealer, once the responder's `KEY_SHARE` came back (``Radio/seal(_:with:)``).
        case seal(ChannelID, LinkSealer)
        /// The link registered (``Radio/linkUp(_:on:)``): the bit flip's switch arms here.
        case linkUp(ChannelID)
        /// Our plain dial to this address got no reply (``Radio/dialGotNoReply(at:)``).
        case dialGotNoReply(RadioAddress)
        case close(ChannelID)
        case ring(ChannelID)
        case heardHello(ChannelID, NodeId, told: NodeId?, announced: NodeId?)
        /// A paused channel fell below half its credit (``Mailbox/consumed(_:on:)``), with this many bytes still
        /// unprocessed: the loop polls it for input again.
        case resumeReading(ChannelID, unprocessed: Int)
        case shutdown
    }

    /// Hands commands to the radio's thread and wakes it through a pipe, and numbers channels for both sides:
    /// ``BlueZRadio/dial(_:psm:)`` must answer an id at once, and the loop numbers the channels it accepts from the
    /// same counter, so no two ever share one.
    ///
    /// It is the radio's entry point, so it counts each channel's level too (``OutboxLevels``): a write's bytes are queued
    /// as it is posted, before the loop takes them, and a channel counts from the moment it is numbered. Its inbound
    /// credit counts from then as well (``InboxCredits``), and what the consumer reports processed comes off it here,
    /// on the consumer's thread, waking the loop only to resume a paused channel.
    internal final class Mailbox: Sendable {
        private struct State {
            var commands: [RadioCommand] = []
            var nextChannel: UInt64 = 1
        }

        private static let drainSize = 64

        private let state = Lock(State())
        /// Every open channel's queued and written bytes, which the loop moves as its sockets take them.
        let levels = OutboxLevels()
        /// Every open channel's bytes delivered and not yet processed, which the loop reads before it polls a channel
        /// for input (ADR 2026-10.f5zs, rule 6).
        let credits = InboxCredits()
        /// The pipe's read end, which the loop polls. If `pipe` failed both ends are -1, which `poll` skips; the
        /// loop then sees commands at its next timeout instead of at once.
        let descriptor: Int32
        private let wakeEnd: Int32

        init() {
            var ends: [Int32] = [-1, -1]
            if pipe(&ends) == 0 {
                ends.forEach(Descriptor.makeNonBlocking)
            } else {
                ends = [-1, -1]
            }
            descriptor = ends[0]
            wakeEnd = ends[1]
        }

        deinit {
            for end in [descriptor, wakeEnd] where end >= 0 {
                Glibc.close(end)
            }
        }

        /// Queues `command` and wakes the loop. A full pipe already holds a wake-up, so a failed write loses nothing.
        func post(_ command: RadioCommand) {
            switch command {
            case .write(let id, let bytes), .writeDigest(let id, let bytes), .writeFileRecord(let id, let bytes),
                .writeKeyShare(let id, let bytes, _):
                levels.queued(bytes.count, on: id)
            default:
                break
            }
            state.withLock { $0.commands.append(command) }
            var wake: UInt8 = 1
            _ = Glibc.write(wakeEnd, &wake, 1)
        }

        /// Everything queued since the last call, in order.
        func take() -> [RadioCommand] {
            var sink = [UInt8](repeating: 0, count: Self.drainSize)
            while Glibc.read(descriptor, &sink, Self.drainSize) == Self.drainSize {
                continue
            }
            return state.withLock { state in
                defer { state.commands.removeAll() }
                return state.commands
            }
        }

        /// A channel id never used before, counted from now (``levels``).
        func nextChannel() -> ChannelID {
            let id = state.withLock { state in
                defer { state.nextChannel += 1 }
                return ChannelID(state.nextChannel)
            }
            levels.open(id)
            credits.open(id)
            return id
        }

        /// The consumer processed `count` of `id`'s bytes. Once that resumes a paused channel, the loop is woken to poll it
        /// for input again, as a write wakes it: it may be waiting in `poll` for the idle second.
        func consumed(_ count: Int, on id: ChannelID) {
            guard let unprocessed = credits.consumed(count, on: id) else {
                return
            }
            post(.resumeReading(id, unprocessed: unprocessed))
        }
    }
#endif
