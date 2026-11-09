#if os(Linux)
    @testable import KnitBlueZ
    import KnitCrypto
    import KnitMesh
    import KnitSync
    import KnitWire
    import Testing

    /// A sealed link through the radio's public face (the `link-seal` contract, §4 and §5): every `Radio` call a link
    /// manager makes on a sealed channel lands on the radio's own thread in order, and the far end reads our KEY_SHARE, then
    /// only frames that open in order to what was handed over, its levels counted in plaintext.
    @Suite(.timeLimit(.minutes(1))) struct BlueZRadioSealTests {
        private final class Collector: Sendable {
            private let events = Lock<[RadioEvent]>([])
            private let finished = Lock(false)

            var all: [RadioEvent] { events.withLock { $0 } }
            var isFinished: Bool { finished.withLock { $0 } }

            func take(_ stream: AsyncStream<RadioEvent>) async {
                for await event in stream {
                    events.withLock { $0.append(event) }
                }
                finished.withLock { $0 = true }
            }
        }

        private func settle(_ fake: FakeBlueZ, until condition: () -> Bool) async -> Bool {
            let deadline = Monotonic.milliseconds() + LoopRig.settleMilliseconds
            while !condition(), Monotonic.milliseconds() < deadline {
                fake.iterate(waitMilliseconds: 2)
                await Task.yield()
            }
            return condition()
        }

        private static func halves() throws -> (sealer: LinkSealer, opener: LinkOpener) {
            let ours = LinkSeal.Ephemeral()
            let theirs = LinkSeal.Ephemeral()
            let sealing = try LinkSeal.derive(ours, peerShare: theirs.keyShare, role: .dialer)
            let opening = try LinkSeal.derive(theirs, peerShare: ours.keyShare, role: .responder)
            return (sealing.sealer, opening.opener)
        }

        /// A started radio, its events collected, and a remote end that dialed it on the channel it accepted.
        private struct Accepted {
            let radio: BlueZRadio
            let collector: Collector
            let listening: Task<Void, Never>
            let remote: RemoteEnd
            let id: ChannelID
        }

        /// A started radio on the fake BlueZ, its events collected, and a remote end that dialed it: the channel it accepted.
        private func accepted(_ fake: FakeBlueZ) async throws -> Accepted {
            let sockets = UnixSockets(directory: UnixSockets.temporaryDirectory(), limit: 60_000)
            var configuration = BlueZRadio.Configuration(
                adapter: try AdapterSelection(name: "hci1", expectedAddress: FakeBlueZ.adapterAddress),
                profile: .android,
                objectRoot: "/app/getknit/radio",
                log: CapturingLog()
            )
            configuration.bus = .peer(fake.address)
            configuration.sockets = sockets
            let radio = BlueZRadio(configuration: configuration)
            let collector = Collector()
            let listening = Task { await collector.take(radio.events) }
            radio.start()
            #expect(await settle(fake) { collector.all.contains(.listening(psm: UnixSockets.psm)) })
            let remote = try RemoteEnd.dial(sockets)
            #expect(await settle(fake) { collector.all.contains { event in if case .accepted = event { true } else { false } } })
            let id = try #require(
                collector.all.compactMap { event -> ChannelID? in if case .accepted(let id) = event { id } else { nil } }.first)
            return Accepted(radio: radio, collector: collector, listening: listening, remote: remote, id: id)
        }

        /// The far end's reading of `bytes` past our KEY_SHARE: every frame opened in order, and the records inside.
        private static func opened(_ bytes: [UInt8], with opener: LinkOpener) throws -> [[UInt8]] {
            var outer = LinkRecordReader()
            outer.append(bytes)
            var inner = LinkRecordReader()
            while let record = try outer.next() {
                #expect(record.tag == .sealed)
                inner.append(try #require(opener.open(sealedPayload: record.payload)))
            }
            var records: [[UInt8]] = []
            while let record = try inner.next() {
                records.append(record.encoded ?? [])
            }
            return records
        }

        @Test func aSealedChannelCarriesOnlyFramesThatOpenToWhatWasHandedOver() async throws {
            let fake = try FakeBlueZ()
            let link = try await accepted(fake)
            let (radio, collector, remote, id) = (link.radio, link.collector, link.remote, link.id)
            #expect(radio.reportsFileWrites)
            let (sealer, opener) = try Self.halves()
            let share = LinkRecord(.keyShare, payload: [UInt8](repeating: 0x5E, count: 32)).encoded ?? []
            let hello = LinkRecord(.hello, payload: [UInt8](repeating: 0x48, count: 40)).encoded ?? []
            let digest = LinkRecord(.digest, payload: [UInt8](repeating: 0xD1, count: 30)).encoded ?? []
            let file = LinkRecord(.fileChunk, payload: [UInt8](repeating: 0x42, count: 20_000)).encoded ?? []
            radio.writeKeyShare(share, sealer: nil, to: id)
            radio.write(hello, to: id)
            radio.heardHello(from: LoopRig.advert().advertised, on: id)
            radio.dialGotNoReply(at: RadioAddress(LoopRig.peerPath))
            radio.seal(id, with: sealer)
            radio.linkUp(LoopRig.advert().advertised, on: id)
            radio.writeDigest(digest, to: id)
            radio.writeFileRecord(file, to: id)
            radio.ring(id)
            let handed = Int64(share.count + hello.count + digest.count + file.count)
            var received: [UInt8] = []
            let drained = await settle(fake) {
                while let sdu = remote.receive(timeoutMilliseconds: 0) {
                    received += sdu
                }
                return radio.outboxLevel(on: id).writtenBytes == handed
            }
            #expect(drained)
            #expect(radio.outboxLevel(on: id) == OutboxLevel(queuedBytes: 0, writtenBytes: handed), "plaintext, all of it")
            #expect(await settle(fake) { collector.all.contains(.wroteFileRecord(id)) })
            while let sdu = remote.receive(timeoutMilliseconds: 100) {
                received += sdu
            }
            #expect(Array(received.prefix(share.count)) == share, "the KEY_SHARE goes in the clear, first")
            #expect(try Self.opened(Array(received.dropFirst(share.count)), with: opener) == [hello, digest, file])
            radio.consumed(received.count, on: id)
            radio.close(id)
            #expect(await settle(fake) { collector.all.contains(.closed(id)) })
            let shutdown = Task { await radio.shutdown() }
            #expect(await settle(fake) { collector.isFinished })
            await shutdown.value
            await link.listening.value
        }
    }
#endif
