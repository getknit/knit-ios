#if os(Linux)
    import Glibc
    import KnitMesh
    import KnitWire
    import KnitSync

    /// What the radio's callers ask of its thread.
    internal enum RadioCommand: Equatable, Sendable {
        case start
        case stop
        case advertise(AdvertPayload)
        case dial(ChannelID, RadioAddress, psm: UInt16)
        case write(ChannelID, [UInt8])
        case writeDigest(ChannelID, [UInt8])
        case close(ChannelID)
        case ring(ChannelID)
        case heardHello(ChannelID, NodeId)
        case shutdown
    }

    /// Hands commands to the radio's thread and wakes it through a pipe, and numbers channels for both sides:
    /// ``BlueZRadio/dial(_:psm:)`` must answer an id at once, and the loop numbers the channels it accepts from the
    /// same counter, so no two ever share one.
    internal final class Mailbox: Sendable {
        private struct State {
            var commands: [RadioCommand] = []
            var nextChannel: UInt64 = 1
        }

        private static let drainSize = 64

        private let state = Lock(State())
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

        /// A channel id never used before.
        func nextChannel() -> ChannelID {
            state.withLock { state in
                defer { state.nextChannel += 1 }
                return ChannelID(state.nextChannel)
            }
        }
    }
#endif
