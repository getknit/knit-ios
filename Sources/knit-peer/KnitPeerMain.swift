import Foundation

#if os(Linux)
    import Dispatch
    import Glibc
    import KnitBlueZ
    import KnitCrypto
    import KnitMesh
    import KnitPeer
    import KnitStore
    import KnitWire
    import Synchronization

    /// `knit-peer`: a headless Knit node on a BlueZ adapter that is never `hci0` (`.agents/context/linux-peer.md`).
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
                await scan(options)
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

        /// Lists the nodes in range without linking: the radio is driven directly, with no link manager to dial.
        private static func scan(_ options: ScanOptions) async {
            let log = JSONLinesLog(
                threshold: JSONLinesLog.level(named: options.logLevel) ?? .info, clock: SystemClock(), write: Lines.error.write)
            let selection = checkedAdapter(options.adapter, options.adapterAddress, log: log)
            let profile = options.advertise.flatMap(RadioProfile.init(name:))
            var configuration = BlueZRadio.Configuration(adapter: selection, profile: profile ?? .android, log: log)
            configuration.readsGattPayloads = true
            let radio = BlueZRadio(configuration: configuration)
            var own: NodeId?
            if profile != nil {
                do {
                    own = try PeerState(directory: options.stateDirectory).loadIdentity().keys.nodeId
                } catch {
                    fail("cannot load the identity in \(options.stateDirectory): \(error)")
                }
            }
            var report = ScanReport(own: own)
            let deadline = ContinuousClock.now.advanced(by: .seconds(options.seconds))
            let stopper = Task {
                try? await Task.sleep(until: deadline, clock: .continuous)
                await radio.shutdown()
            }
            radio.start()
            for await event in radio.events {
                switch event {
                case .listening(let psm):
                    if let own {
                        radio.advertise(AdvertPayload(capabilities: .local, nodeId: own, digestCue: 0, psm: psm))
                        log.log(.info, "advertising \(own) on PSM \(psm)")
                    }
                case .sighted(let sighting):
                    report.take(sighting).map(Lines.output.write)
                case .accepted(let channel):
                    // Someone dialed the advert anyway: hang up before any HELLO.
                    radio.close(channel)
                case .state(let state) where state != .on:
                    log.log(.warning, "radio \(state)")
                default:
                    continue
                }
            }
            _ = await stopper.result
            Lines.output.write(report.summary)
        }

        private static func checkedAdapter(_ name: String, _ address: String, log: any KnitLog) -> AdapterSelection {
            do {
                let selection = try AdapterSelection(name: name, expectedAddress: address)
                let status = try AdapterProbe.check(selection)
                log.log(.info, "adapter \(selection.name) is \(selection.address), \(status.powered ? "powered" : "not powered")")
                return selection
            } catch {
                fail("refusing to start: \(error)")
            }
        }

        private static func run(_ options: RunOptions) async {
            let log: any KnitLog =
                options.logLevel.flatMap(JSONLinesLog.level(named:)).map { level in
                    JSONLinesLog(threshold: level, clock: SystemClock(), write: Lines.error.write)
                }
                ?? SilentLog()
            let selection = checkedAdapter(options.adapter, options.adapterAddress, log: log)
            let profile = RadioProfile(name: options.radioProfile) ?? .android
            var radioConfiguration = BlueZRadio.Configuration(adapter: selection, profile: profile, log: log)
            let receiveMTU = options.receiveMTU.flatMap(UInt16.init(exactly:))
            let sendMTU = options.sendMTU.flatMap(UInt16.init(exactly:))
            if receiveMTU != nil || sendMTU != nil {
                radioConfiguration.sockets = L2CAPSockets(
                    adapter: selection.address,
                    receiveMTU: receiveMTU ?? L2CAPSockets.largestReceiveMTU,
                    sendMTU: sendMTU ?? L2CAPSockets.defaultSendMTU
                )
                let offered = receiveMTU.map(String.init) ?? "the default"
                let written = sendMTU ?? L2CAPSockets.defaultSendMTU
                log.log(.info, "channels offer a receive MTU of \(offered) and write at most \(written)")
            }
            let radio = BlueZRadio(configuration: radioConfiguration)
            var links = LinkManager.Configuration()
            if let floor = options.rssiFloor {
                links.promotion.rssiFloor = Double(floor)
                log.log(.info, "promotion floor loosened to \(floor) dBm for development; Android's is -90")
            }
            let node = makeNode(options, radio: radio, profile: profile, links: links, log: log)
            let signals = stopOnSignals(node, radio)
            await node.start(name: options.name)
            for await line in StandardInput.lines() where !line.isEmpty {
                guard await node.handle(line) else {
                    break
                }
            }
            await node.stop()
            await radio.shutdown()
            for source in signals {
                source.cancel()
            }
        }

        /// The node, on the identity and profile kept in the state directory, with everything else in memory.
        private static func makeNode(
            _ options: RunOptions,
            radio: BlueZRadio,
            profile: RadioProfile,
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
                ownProfile: state.profileStore()
            )
            return PeerNode(
                identity: identity.keys,
                stores: stores,
                radio: radio,
                radioProfile: profile.name,
                clock: SystemClock(),
                random: SystemRandomNumberGenerator(),
                linkConfiguration: links,
                log: log,
                output: Lines.output.write
            )
        }

        /// Stops cleanly on `SIGINT` and `SIGTERM`: the advert is withdrawn and every link closed before the exit.
        private static func stopOnSignals(_ node: PeerNode, _ radio: BlueZRadio) -> [any DispatchSourceSignal] {
            [SIGINT, SIGTERM].map { number in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler {
                    Task {
                        await node.stop()
                        await radio.shutdown()
                        exit(0)
                    }
                }
                source.resume()
                return source
            }
        }

        private static func fail(_ message: String) -> Never {
            Lines.error.write(JSONValue.object(["log": "error", "message": .string(message)]).line)
            exit(1)
        }
    }

    /// Standard output or standard error, written one whole line at a time whoever writes.
    internal final class Lines: Sendable {
        static let output = Lines(FileHandle.standardOutput)
        static let error = Lines(FileHandle.standardError)

        private let handle: Mutex<FileHandle>

        private init(_ handle: FileHandle) {
            self.handle = Mutex(handle)
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
            FileHandle.standardError.write(Data("knit-peer drives BlueZ, so it runs on Linux only.\n".utf8))
            exit(1)
        }
    }
#endif
