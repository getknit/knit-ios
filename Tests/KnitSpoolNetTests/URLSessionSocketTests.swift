#if canImport(Darwin)
    import Foundation
    import KnitSync
    import KnitWire
    import Testing

    @testable import KnitMesh
    @testable import KnitSpoolNet

    /// The URLSession adapter's socket against the stub server on loopback (ADR 2026-11.adrq, P5), in `test:macos` on every
    /// run: what is read and when, how a socket ends, and how sends meet a relay that never reads. The stub is the oracle for
    /// the network's side: what it wrote, and when it saw the client's end.
    @Suite(.timeLimit(.minutes(2))) struct URLSessionSocketTests {
        // MARK: Reading

        @Test func aWholeRecordSentSlowlyArrivesWhole() async throws {
            let record = (0..<SpoolRecordLayer.maxInboundRecord).map { UInt8(truncatingIfNeeded: $0 &* 7) }
            let stub = try #require(StubServer([.upgrade(headers: [], steps: [.binarySlowly(record, chunk: 8192, pauseMilliseconds: 20)])]))
            defer { stub.stop() }
            let dialer = Dialer()
            let socket = try await dialer.socket(stub.url())
            #expect(await socket.receive() == .binary(record))
            socket.close(code: SpoolCloseCode.normal)
        }

        @Test func aMessagePastTheRecordCapEndsTheSocket() async throws {
            let stub = try #require(
                StubServer([.upgrade(headers: [], steps: [.binary([UInt8](repeating: 1, count: SpoolRecordLayer.maxInboundRecord + 1))])]))
            defer { stub.stop() }
            let dialer = Dialer()
            let socket = try await dialer.socket(stub.url())
            guard case .closed(let end) = await socket.receive() else {
                Issue.record("an oversize message was delivered")
                return
            }
            #expect(end.fault == .protocolError, "ended as \(end)")
            #expect(await stub.ended(0, within: .seconds(5)) != nil, "the stub saw the connection end")
            #expect(await socket.receive() == .closed(end), "every later receive answers the same")
        }

        /// One message as 125-byte continuation frames to one byte past the cap: refused by the same rule, frames or not.
        @Test func aFragmentedMessagePastTheCapEndsTheSocket() async throws {
            let total = SpoolRecordLayer.maxInboundRecord + 1
            let stub = try #require(StubServer([.upgrade(headers: [], steps: [.fragments(total: total, frameSize: 125)])]))
            defer { stub.stop() }
            let dialer = Dialer()
            let socket = try await dialer.socket(stub.url())
            guard case .closed(let end) = await socket.receive() else {
                Issue.record("an oversize fragmented message was delivered")
                return
            }
            #expect(end.fault == .protocolError, "ended as \(end)")
            #expect(await stub.ended(0, within: .seconds(5)) != nil)
        }

        /// A text message is reported by its size, and the connection stays: the next binary message arrives.
        @Test func aTextMessageIsReportedBySizeAndTheSocketStays() async throws {
            let stub = try #require(StubServer([.upgrade(headers: [], steps: [.text("héllo"), .binary([1, 2, 3])])]))
            defer { stub.stop() }
            let dialer = Dialer()
            let socket = try await dialer.socket(stub.url())
            #expect(await socket.receive() == .text(byteCount: 6))
            #expect(await socket.receive() == .binary([1, 2, 3]))
            socket.close(code: SpoolCloseCode.normal)
        }

        /// The extension the task offers, taken: a compressed message is read as its inflated bytes, up to the cap.
        @Test(arguments: [1000, SpoolRecordLayer.maxInboundRecord])
        func aCompressedMessageArrivesInflated(_ size: Int) async throws {
            let record = (0..<size).map { UInt8(truncatingIfNeeded: $0 % 251) }
            let deflate = [("Sec-WebSocket-Extensions", Array(SpoolTaskWatch.offeredExtension.utf8))]
            let stub = try #require(StubServer([.upgrade(headers: deflate, steps: [.deflated(record)])]))
            defer { stub.stop() }
            let dialer = Dialer()
            let socket = try await dialer.socket(stub.url())
            #expect(await socket.receive() == .binary(record))
            socket.close(code: SpoolCloseCode.normal)
        }

        /// The record cap holds on the inflated size: a small compressed message that inflates past it ends the socket.
        @Test func aCompressedMessageInflatingPastTheCapEndsTheSocket() async throws {
            let bomb = [UInt8](repeating: 0, count: 8 << 20)
            let deflate = [("Sec-WebSocket-Extensions", Array(SpoolTaskWatch.offeredExtension.utf8))]
            #expect(StubServer.deflate(bomb).count < SpoolRecordLayer.maxInboundRecord, "the compressed message is under the cap")
            let stub = try #require(StubServer([.upgrade(headers: deflate, steps: [.deflated(bomb)])]))
            defer { stub.stop() }
            let dialer = Dialer()
            let socket = try await dialer.socket(stub.url())
            guard case .closed(let end) = await socket.receive() else {
                Issue.record("a message inflating past the cap was delivered")
                return
            }
            #expect(end.fault == .protocolError, "ended as \(end)")
            #expect(await stub.ended(0, within: .seconds(5)) != nil)
        }

        /// Nothing is read ahead of the reader: 64 MiB written to a socket nobody reads stall at the kernel's buffers.
        @Test func nothingIsReadAheadOfTheReader() async throws {
            let stub = try #require(StubServer([.upgrade(headers: [], steps: [.flood(count: 1024, size: 65_536)])]))
            defer { stub.stop() }
            let dialer = Dialer()
            let socket = try await dialer.socket(stub.url())
            let flooded = try #require(await stub.flooded(0, within: .seconds(60)))
            #expect(flooded.stalled, "the stub's writes stalled after \(flooded.written) bytes")
            #expect(flooded.written < 16 << 20, "a few MiB at most, never the 64: \(flooded.written) bytes")
            socket.close(code: SpoolCloseCode.normal)
        }

        // MARK: Ending

        struct Close: Sendable, CustomTestStringConvertible {
            let code: UInt16
            var testDescription: String { "\(code)" }
        }

        /// A close reaches the plane as its code, its reason dropped whatever its length.
        @Test(arguments: [Close(code: 1000), Close(code: 1001), Close(code: 4001), Close(code: 4003)])
        func aCloseArrivesAsItsCodeWithNoReason(_ close: Close) async throws {
            let reason = Array(String(repeating: "r", count: 123).utf8)
            let stub = try #require(StubServer([.upgrade(headers: [], steps: [.close(code: close.code, reason: reason)])]))
            defer { stub.stop() }
            let dialer = Dialer()
            let socket = try await dialer.socket(stub.url())
            let message = await socket.receive()
            #expect(message == .closed(SpoolSocketEnd(.closed, code: Int(close.code))), "\(message)")
            #expect(!"\(message)".contains("rrr"))
        }

        /// A receive whose task is cancelled ends at once with the socket, and the stub sees the connection go.
        @Test func aCancelledReceiveEndsWithinATick() async throws {
            let stub = try #require(StubServer([.upgrade(headers: [], steps: [])]))
            defer { stub.stop() }
            let dialer = Dialer()
            let socket = try await dialer.socket(stub.url())
            let reading = Task { await socket.receive() }
            await Task.yield()
            let cancelled = ContinuousClock.now
            reading.cancel()
            #expect(await reading.value == .closed(SpoolSocketEnd(.cancelled)))
            #expect(ContinuousClock.now - cancelled < SocketRace.tick)
            #expect(await stub.ended(0, within: SocketRace.tick) != nil, "the stub saw the connection end")
            #expect(await socket.send([1]) == false, "the socket is over")
        }

        /// A relay that never reads: each send waits for the task to take its bytes, so sends stop at the buffers, and a close
        /// ends the one waiting.
        @Test func sendsToARelayThatNeverReadsStallAndACloseEndsThem() async throws {
            let stub = try #require(StubServer([.upgrade(headers: [], steps: [.holdUnread])]))
            defer { stub.stop() }
            let dialer = Dialer()
            let socket = try await dialer.socket(stub.url())
            let record = [UInt8](repeating: 0x42, count: 65_536)
            var sent = 0
            var stalled: Task<Bool, Never>?
            for _ in 0..<1024 {
                let sending = Task { await socket.send(record) }
                let finished = await SocketRace.finishes(sending, within: .seconds(2))
                guard finished else {
                    stalled = sending
                    break
                }
                sent += record.count
            }
            let waiting = try #require(stalled, "a send stalled")
            #expect(sent < 32 << 20, "the sends stopped at the buffers, after \(sent) bytes")
            socket.close(code: SpoolCloseCode.normal)
            #expect(await SocketRace.finishes(waiting, within: SocketRace.tick), "the close ended the waiting send")
            #expect(await waiting.value == false)
            stub.drain()
            #expect(await stub.ended(0, within: .seconds(10)) != nil, "the stub saw the connection end")
        }
    }
#endif
