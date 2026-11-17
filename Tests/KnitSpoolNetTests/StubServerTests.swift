import Foundation
import Testing

/// The stub server itself, through a raw TCP client (ADR 2026-11.adrq, P5): it is the adapter tests' oracle, so what it
/// answers and records is checked on every platform, before a Mac reads anything from it.
@Suite(.timeLimit(.minutes(1))) struct StubServerTests {
    private static let request = Array(
        ("GET /spool/v1 HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n").utf8)

    private func head(_ descriptor: Int32) -> String {
        var bytes: [UInt8] = []
        while !bytes.suffix(4).elementsEqual(Array("\r\n\r\n".utf8)), let byte = Loopback.read(descriptor, limit: 1) {
            bytes += byte
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    @Test func aRefusalCarriesItsStatusAndTheRetryAfterBytesAsGiven() async throws {
        let raw: [UInt8] = [0x31, 0x32, 0xE9, 0x20]
        let stub = try #require(StubServer([.http(status: 503, headers: [("Retry-After", raw)])]))
        defer { stub.stop() }
        let client = try #require(Loopback.connect(port: stub.port))
        defer { Loopback.close(client) }
        Loopback.write(client, Self.request)
        var answer: [UInt8] = []
        while let more = Loopback.read(client) {
            answer += more
        }
        #expect(answer.starts(with: Array("HTTP/1.1 503 ".utf8)))
        let line = Array("Retry-After: ".utf8) + raw + Array("\r\n".utf8)
        #expect((0...(answer.count - line.count)).contains { answer[$0...].starts(with: line) }, "the header's bytes as given")
        #expect(await stub.accepted(1, within: .seconds(5)))
        #expect(stub.connections.first?.head.contains("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==") == true, "the head is kept")
    }

    /// RFC 6455's own example key and accept, then a binary frame, a text frame and a close.
    @Test func anUpgradeAnswersRFC6455sAcceptThenItsFrames() async throws {
        let stub = try #require(
            StubServer([
                .upgrade(
                    headers: [], steps: [.binary([1, 2, 3]), .text("hi"), .close(code: 4001, reason: Array("why".utf8)), .readFrame])
            ]))
        defer { stub.stop() }
        let client = try #require(Loopback.connect(port: stub.port))
        defer { Loopback.close(client) }
        Loopback.write(client, Self.request)
        let answer = head(client)
        #expect(answer.hasPrefix("HTTP/1.1 101 "))
        #expect(StubServer.header("sec-websocket-accept", in: answer) == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        #expect(Loopback.read(client, exactly: 5) == [0x82, 3, 1, 2, 3])
        #expect(Loopback.read(client, exactly: 4) == [0x81, 2] + Array("hi".utf8))
        #expect(Loopback.read(client, exactly: 7) == [0x88, 5, 0x0F, 0xA1] + Array("why".utf8))
        // A masked client frame, unmasked by the stub.
        let mask: [UInt8] = [9, 8, 7, 6]
        Loopback.write(client, [0x82, 0x80 | 2] + mask + [1 ^ 9, 2 ^ 8])
        Loopback.shutdownWrite(client)
        #expect(await stub.ended(0, within: .seconds(5)) != nil, "the stub saw the client's end")
        #expect(stub.connections.first?.frames == [[1, 2]])
    }

    @Test func framesOfEveryLengthEncodeTheirLength() {
        #expect(StubServer.frame(opcode: 0x2, [UInt8](repeating: 0, count: 125)).prefix(2) == [0x82, 125])
        #expect(StubServer.frame(opcode: 0x2, [UInt8](repeating: 0, count: 126)).prefix(4) == [0x82, 126, 0, 126])
        #expect(
            StubServer.frame(opcode: 0x0, [UInt8](repeating: 0, count: 65_536), fin: false).prefix(10) == [
                0x00, 127, 0, 0, 0, 0, 0, 1, 0, 0,
            ])
    }

    /// A flood into a client that reads nothing stalls at the kernel's buffers, and the stub says so.
    @Test func aFloodIntoAClientThatNeverReadsStalls() async throws {
        let stub = try #require(StubServer([.upgrade(headers: [], steps: [.flood(count: 1024, size: 65_536)])]))
        defer { stub.stop() }
        let client = try #require(Loopback.connect(port: stub.port))
        defer { Loopback.close(client) }
        Loopback.write(client, Self.request)
        _ = head(client)
        let flooded = try #require(await stub.flooded(0, within: .seconds(30)))
        #expect(flooded.stalled, "the writes stalled")
        #expect(flooded.written < 64 << 20, "well short of the 64 MiB")
    }

    @Test func aStopEndsEveryConnection() async throws {
        let stub = try #require(StubServer([.silence]))
        let client = try #require(Loopback.connect(port: stub.port))
        defer { Loopback.close(client) }
        Loopback.write(client, Self.request)
        #expect(await stub.accepted(1, within: .seconds(5)))
        stub.stop()
        #expect(Loopback.read(client) == nil, "the connection ended")
    }

    /// The steps the Mac's adapter cases use, read raw: a slow message, a fragmented one, a pause, and a hold that only a
    /// drain lets go.
    @Test func theSlowFragmentedPausedAndHeldStepsWriteWhatTheySay() async throws {
        let stub = try #require(
            StubServer([
                .upgrade(
                    headers: [],
                    steps: [
                        .binarySlowly([1, 2, 3, 4], chunk: 2, pauseMilliseconds: 1), .fragments(total: 5, frameSize: 2),
                        .pause(milliseconds: 1), .holdUnread,
                    ])
            ]))
        defer { stub.stop() }
        #expect(stub.url(query: "x=1") == "ws://127.0.0.1:\(stub.port)/spool/v1?x=1")
        let client = try #require(Loopback.connect(port: stub.port))
        defer { Loopback.close(client) }
        Loopback.write(client, Self.request)
        _ = head(client)
        #expect(Loopback.read(client, exactly: 6) == [0x82, 4, 1, 2, 3, 4])
        let fragments: [UInt8] = [0x02, 2, 0x5A, 0x5A, 0x00, 2, 0x5A, 0x5A, 0x80, 1, 0x5A]
        #expect(Loopback.read(client, exactly: fragments.count) == fragments)
        Loopback.shutdownWrite(client)
        #expect(await stub.ended(0, within: .milliseconds(300)) == nil, "a held connection reads nothing")
        stub.drain()
        #expect(await stub.ended(0, within: .seconds(5)) != nil, "the drain lets it read to the client's end")
    }
}
