import Foundation

#if os(Linux) || os(macOS)
    import Dispatch
    import KnitControl
    import KnitCrypto
    import KnitMesh
    import KnitPeer
    import KnitStore
    import KnitWire
    import KnitSync
    #if os(Linux)
        import Glibc
    #endif

    /// `knit-peer`: a headless Knit node. On Linux its radio is a BlueZ adapter found by its address, never the
    /// maintainer's unshared (`.agents/context/linux-peer.md`); on a Mac it is CoreBluetooth, the iPhone's own radio
    /// (``PeerHost``).
    @main
    internal enum KnitPeerMain {
        // The @main attribute calls it, which `swiftlint analyze` does not see.
        // swiftlint:disable:next unused_declaration
        static func main() async {
            let command: PeerCommand
            do {
                command = try PeerCommand.parse(Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment)
            } catch {
                Lines.error.write(PeerCommand.usage)
                fail("\(error)")
            }
            switch command {
            case .help:
                Lines.output.write(PeerCommand.usage)
            case .keygen(let options):
                keygen(options)
            case .scan(let options):
                let host: any PeerRadioHost.Type = PeerHost.self
                await host.scan(options)
            case .run(let options):
                await run(options)
            }
        }

        private static func keygen(_ options: KeygenOptions) {
            do {
                let keys = try KeyGen.identity(in: options.window)
                try PeerState(directory: options.stateDirectory).replaceIdentity(with: keys)
                let reply: JSONValue = [
                    "reply": "keygen", "ok": true, "nodeId": .string(keys.nodeId.string), "state": .string(options.stateDirectory),
                ]
                Lines.output.write(reply.line)
            } catch {
                fail("keygen failed: \(error)")
            }
        }

        private static func run(_ options: RunOptions) async {
            let log: any KnitLog =
                options.logLevel.flatMap(JSONLinesLog.level(named:)).map { level in
                    JSONLinesLog(threshold: level, clock: SystemClock(), write: Lines.error.write)
                }
                ?? SilentLog()
            let kind: any PeerRadioHost.Type = PeerHost.self
            let host: any PeerRadioHost
            do {
                host = try kind.init(options, log: log)
            } catch {
                fail("refusing to start: \(error)")
            }
            var links = LinkManager.Configuration()
            if let floor = options.rssiFloor {
                links.promotion.rssiFloor = Double(floor)
                log.log(.info, "promotion floor loosened to \(floor) dBm for development; Android's is -90")
            }
            let node = makeNode(options, host: host, links: links, log: log)
            let signals = stopOnSignals(node, host)
            await node.start(name: options.name)
            for await line in StandardInput.lines() where !line.isEmpty {
                guard await node.handle(line) else {
                    break
                }
            }
            await node.stop()
            await host.shutdown()
            for source in signals {
                source.cancel()
            }
        }

        /// The node, on the identity and profile kept in the state directory, with everything else in memory.
        private static func makeNode(
            _ options: RunOptions,
            host: any PeerRadioHost,
            links: LinkManager.Configuration,
            log: any KnitLog
        ) -> PeerNode {
            let state = PeerState(directory: options.stateDirectory)
            let identity: IdentityKeys.Loaded
            do {
                identity = try state.loadIdentity()
            } catch {
                fail("cannot load the identity in \(options.stateDirectory): \(error)")
            }
            let stores = MeshStores(
                custody: MemoryCustodyStore(),
                peers: MemoryPeerStore(),
                messages: MemoryMessageStore(),
                conversations: MemoryConversationStore(),
                blocks: MemoryBlockStore(),
                groups: MemoryGroupStore(),
                ownProfile: state.profileStore(),
                blobs: MemoryBlobStore()
            )
            return PeerNode(
                identity: identity.keys,
                stores: stores,
                radio: host.radio,
                radioProfile: host.profile,
                clock: SystemClock(),
                random: SystemRandomNumberGenerator(),
                linkConfiguration: links,
                log: log,
                avatarPath: state.avatarPath,
                output: Lines.output.write
            )
        }

        /// Stops cleanly on `SIGINT` and `SIGTERM`: the advert is withdrawn and every link closed before the exit.
        private static func stopOnSignals(_ node: PeerNode, _ host: any PeerRadioHost) -> [any DispatchSourceSignal] {
            [SIGINT, SIGTERM].map { number in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler {
                    Task {
                        await node.stop()
                        await host.shutdown()
                        exit(0)
                    }
                }
                source.resume()
                return source
            }
        }

        static func fail(_ message: String) -> Never {
            Lines.error.write(JSONValue.object(["log": "error", "message": .string(message)]).line)
            exit(1)
        }
    }

    /// Standard output or standard error, written one whole line at a time whoever writes.
    internal final class Lines: Sendable {
        static let output = Lines(FileHandle.standardOutput)
        static let error = Lines(FileHandle.standardError)

        private let handle: Lock<FileHandle>

        private init(_ handle: FileHandle) {
            self.handle = Lock(handle)
        }

        /// Writes `line`, or loses it. `FileHandle.write(_: Data)` traps on any error, and a failed write to the log
        /// file took both peers of an interop run down mid-line on 2026-09-25: the node must outlive its log.
        @Sendable
        func write(_ line: String) {
            handle.withLock { try? $0.write(contentsOf: Data((line + "\n").utf8)) }
        }
    }

    /// Standard input as lines, read on a thread of their own so the mesh never waits on the terminal.
    ///
    /// It reads file descriptor 0 with `read(2)` rather than through stdio: a thread blocked in `readLine()` holds
    /// stdin's `FILE` lock, and `exit()` then waits for it forever while it flushes every stream.
    internal enum StandardInput {
        private static let chunk = 4096
        private static let newline = UInt8(ascii: "\n")

        static func lines() -> AsyncStream<String> {
            let (lines, continuation) = AsyncStream<String>.makeStream()
            let reader = Thread {
                var pending: [UInt8] = []
                var buffer = [UInt8](repeating: 0, count: chunk)
                while true {
                    let count = read(STDIN_FILENO, &buffer, chunk)
                    if count < 0, errno == EINTR {
                        continue
                    }
                    guard count > 0 else {
                        break
                    }
                    pending += buffer[0..<count]
                    while let end = pending.firstIndex(of: newline) {
                        // A control line is JSON, so a malformed byte only makes a line that fails to parse.
                        // swiftlint:disable:next optional_data_string_conversion
                        continuation.yield(String(decoding: pending[..<end], as: UTF8.self))
                        pending.removeSubrange(...end)
                    }
                }
                if !pending.isEmpty {
                    // swiftlint:disable:next optional_data_string_conversion
                    continuation.yield(String(decoding: pending, as: UTF8.self))
                }
                continuation.finish()
            }
            reader.name = "knit-peer-stdin"
            reader.start()
            return lines
        }
    }
#else
    @main
    internal enum KnitPeerMain {
        static func main() {
            FileHandle.standardError.write(Data("knit-peer needs BlueZ on Linux or CoreBluetooth on a Mac.\n".utf8))
            exit(1)
        }
    }
#endif
