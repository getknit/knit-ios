#if canImport(Darwin)
    import Foundation
    import KnitSync
    import KnitWire
    import Testing

    @testable import KnitMesh
    @testable import KnitSpoolNet

    /// The URLSession adapter's dial against the stub server on loopback (ADR 2026-11.adrq, P5), in `test:macos` on every run:
    /// what a failed upgrade reports, how long an upgrade may take, and what the upgrade asks for. The stub is the oracle for
    /// the network's side: what it was asked and when it saw the client's end.
    @Suite(.timeLimit(.minutes(2))) struct URLSessionDialTests {
        // MARK: A failed upgrade

        struct RetryAfter: Sendable, CustomTestStringConvertible {
            let name: String
            let header: [UInt8]
            let milliseconds: Int64?
            var testDescription: String { name }
        }

        static let retryAfters = [
            RetryAfter(name: "digits", header: Array("30".utf8), milliseconds: 30_000),
            RetryAfter(name: "an HTTP-date", header: Array("Wed, 21 Oct 2026 07:28:00 GMT".utf8), milliseconds: nil),
            RetryAfter(name: "twenty nines", header: Array("99999999999999999999".utf8), milliseconds: 60_000),
            RetryAfter(name: "negative", header: Array("-5".utf8), milliseconds: nil),
            RetryAfter(name: "empty", header: [], milliseconds: nil),
            RetryAfter(name: "10 KB of digits", header: [UInt8](repeating: UInt8(ascii: "7"), count: 10_240), milliseconds: 60_000),
            RetryAfter(name: "non-ASCII", header: [0x31, 0xE9, 0x32, 0xFF, 0x80] + Array(repeating: 0xC3, count: 40), milliseconds: nil),
        ]

        /// A full spool's 503: the status and `Retry-After`'s first 16 bytes reach the plane, and its floor reads as the rule says.
        @Test(arguments: retryAfters)
        func aRefusedUpgradeCarriesItsStatusAndRetryAfter(_ variant: RetryAfter) async throws {
            let stub = try #require(StubServer([.http(status: 503, headers: [("Retry-After", variant.header)])]))
            defer { stub.stop() }
            let failure = try await Dialer().failure(stub.url())
            #expect(failure.fault == .http)
            #expect(failure.status == 503, "Apple hands over the refused upgrade's status")
            let kept = failure.retryAfter?.bytes ?? []
            #expect(kept.count <= SpoolRetryAfter.keptBytes, "at most 16 bytes kept")
            #expect(
                failure.retryAfter?.milliseconds == variant.milliseconds, "\(variant.name) reads \(String(describing: failure.retryAfter))")
        }

        /// The session's configuration, as recorded in the P5 amendment: nothing stored, the handshake's 20 s, a day's bound on
        /// a socket, the system's proxy, and Low Data Mode and cellular allowed.
        @Test func theSessionStoresNothingAndBoundsTheHandshake() {
            let made = SpoolSessionDialer.configuration
            #expect(made.httpCookieAcceptPolicy == .never && !made.httpShouldSetCookies && made.httpCookieStorage == nil)
            #expect(made.urlCredentialStorage == nil && made.urlCache == nil)
            #expect(made.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData && !made.waitsForConnectivity)
            #expect(made.timeoutIntervalForRequest == 20 && made.timeoutIntervalForResource == 86_400)
            #expect(made.connectionProxyDictionary == nil, "the system's proxy settings")
            #expect(made.allowsConstrainedNetworkAccess && made.allowsExpensiveNetworkAccess)
        }

        /// A redirect is never followed: the second listener is asked nothing.
        @Test func aRedirectIsNeverFollowed() async throws {
            let target = try #require(StubServer([.upgrade(headers: [], steps: [])]))
            defer { target.stop() }
            let redirect = try #require(StubServer([.http(status: 302, headers: [("Location", Array(target.url().utf8))])]))
            defer { redirect.stop() }
            let failure = try await Dialer().failure(redirect.url())
            #expect(failure.fault == .http && failure.status == 302, "\(failure)")
            #expect(await !target.accepted(1, within: .milliseconds(500)), "nothing reached the redirect's target")
        }

        /// An upgrade that never finishes: the dial's own 20 s deadline fails it and the connection goes.
        @Test func anUpgradeThatNeverFinishesFailsWithinTheHandshake() async throws {
            let stub = try #require(StubServer([.silence]))
            defer { stub.stop() }
            let dialer = Dialer()
            let url = stub.url()
            let started = ContinuousClock.now
            let dialing = Task { try? await dialer.open(url) }
            let answered = await SocketRace.finishes(dialing, within: .seconds(20) + SocketRace.tick * 3)
            let took = ContinuousClock.now - started
            #expect(answered, "the dial answered within the handshake")
            dialing.cancel()
            guard case .failed(let failure)? = await dialing.value else {
                Issue.record("the dial opened")
                return
            }
            #expect(failure == SpoolDialFailure(.unreachable))
            #expect(took >= .seconds(19) && took < .seconds(20) + SocketRace.tick, "at the 20 s handshake, took \(took)")
            #expect(await stub.ended(0, within: SocketRace.tick) != nil, "the stub saw the connection end")
        }

        /// A relay quiet for longer than the handshake keeps its socket: the handshake's deadline bounds the upgrade alone.
        @Test func aSocketQuietPastTheHandshakeStaysOpen() async throws {
            let stub = try #require(StubServer([.upgrade(headers: [], steps: [.pause(milliseconds: 25_000), .binary([7])])]))
            defer { stub.stop() }
            let dialer = Dialer()
            let socket = try await dialer.socket(stub.url())
            #expect(await socket.receive() == .binary([7]))
            socket.close(code: SpoolCloseCode.normal)
        }

        /// A dial cancelled mid-upgrade ends at once, and so does its connection.
        @Test func aCancelledDialEndsWithinATick() async throws {
            let stub = try #require(StubServer([.silence]))
            defer { stub.stop() }
            let dialer = Dialer()
            let url = stub.url()
            let dialing = Task { try await dialer.open(url) }
            #expect(await stub.accepted(1, within: .seconds(5)))
            let cancelled = ContinuousClock.now
            dialing.cancel()
            guard case .failed(let failure) = try await dialing.value else {
                Issue.record("the cancelled dial opened")
                return
            }
            #expect(failure.fault == .cancelled)
            #expect(ContinuousClock.now - cancelled < SocketRace.tick)
            #expect(await stub.ended(0, within: SocketRace.tick) != nil, "the stub saw the connection end")
        }

        // MARK: What goes out

        /// The upgrade request carries `Accept-Language: *` and a fixed `User-Agent`, and no cookie, origin, credential,
        /// subprotocol or extension; a `Set-Cookie` on one upgrade is sent back on no later one.
        @Test func theUpgradeAsksForNothingAndKeepsNoCookie() async throws {
            let stub = try #require(
                StubServer([
                    .upgrade(headers: [("Set-Cookie", Array("spool=1; Path=/".utf8))], steps: [.close(code: 1000, reason: [])]),
                    .upgrade(headers: [], steps: [.close(code: 1000, reason: [])]),
                ]))
            defer { stub.stop() }
            let dialer = Dialer()
            for _ in 0..<2 {
                let socket = try await dialer.socket(stub.url())
                _ = await socket.receive()
            }
            let heads = stub.connections.map(\.head)
            #expect(heads.count == 2)
            for head in heads {
                #expect(StubServer.header("Accept-Language", in: head) == "*", "\(head)")
                #expect(StubServer.header("User-Agent", in: head) == SpoolSessionDialer.userAgent, "\(head)")
                for absent in ["Cookie", "Origin", "Authorization", "Sec-WebSocket-Protocol"] {
                    #expect(StubServer.header(absent, in: head) == nil, "\(absent) in \(head)")
                }
                // The one extension the task offers, which the next cases hold to the record cap.
                #expect(StubServer.header("Sec-WebSocket-Extensions", in: head) == SpoolTaskWatch.offeredExtension, "\(head)")
            }
        }

        struct Named: Sendable, CustomTestStringConvertible {
            let header: String
            let value: String
            var testDescription: String { "\(header): \(value)" }
        }

        /// An upgrade naming a subprotocol, or an extension the task never offered, is refused.
        @Test(arguments: [
            Named(header: "Sec-WebSocket-Protocol", value: "chat"),
            Named(header: "Sec-WebSocket-Extensions", value: "x-webkit-deflate-frame"),
            Named(header: "Sec-WebSocket-Extensions", value: "permessage-deflate, x-other"),
        ])
        func anUpgradeNamingWhatWasNeverOfferedIsRefused(_ named: Named) async throws {
            let stub = try #require(StubServer([.upgrade(headers: [(named.header, Array(named.value.utf8))], steps: [.binary([1])])]))
            defer { stub.stop() }
            let dial = try await Dialer().open(stub.url())
            guard case .failed(let failure) = dial else {
                Issue.record("the dial opened")
                return
            }
            #expect([.protocolError, .http, .unreachable].contains(failure.fault), "\(failure)")
        }

        /// A failed dial says nothing of the address: neither its description, its dump nor its status names the query.
        @Test func aFailedDialCarriesNoPartOfTheAddress() async throws {
            let marker = "zq9spoolmarker"
            let closed = try #require(StubServer([.silence]))
            let port = closed.port
            closed.stop()
            let failure = try await Dialer().failure("ws://127.0.0.1:\(port)/spool/v1?x=\(marker)")
            var dumped = ""
            dump(failure, to: &dumped)
            for shown in ["\(failure)", String(reflecting: failure), dumped] {
                #expect(!shown.contains(marker) && !shown.contains("127.0.0.1"), "\(shown)")
            }
        }
    }
#endif
