#if canImport(Darwin)
    import Foundation
    import KnitWire
    import Testing

    @testable import KnitMesh
    @testable import KnitSpoolNet

    /// The plane's half of the stub cases (ADR 2026-11.adrq, P5): a ``Mesh`` dialling the stub through the URLSession adapter,
    /// its clock moved by the test. The stub says when a connection went; the plane's tasks, counts and next dial say the
    /// rest, and the address never reaches a failure, an end, `status` or the log.
    @Suite(.timeLimit(.minutes(2))) struct SpoolNetPlaneTests {
        private static let tick: Duration = .seconds(1)

        /// An upgrade that never finishes: at the 20 s open deadline the plane drops the dial and the connection goes, no task
        /// is left, the timeout is counted, and the next dial follows the curve.
        @Test func anUpgradeThatNeverFinishesEndsAtTheOpenDeadline() async throws {
            let stub = try #require(StubServer([.silence]))
            defer { stub.stop() }
            let rig = try await MeshOnStub.make(stub.url())
            #expect(await stub.accepted(1, within: .seconds(5)))
            rig.clock.advance(SpoolLink.openMilliseconds)
            #expect(await stub.ended(0, within: Self.tick) != nil, "the stub saw the connection end")
            #expect(await rig.eventually { await $0.spoolTasks.running.isEmpty }, "no task is left")
            let status = try #require(await rig.relayStatus())
            #expect(status.counts["dialTimeouts"] == 1 && status.state == "idle", "\(status)")
            let now = rig.clock.monotonicMilliseconds()
            let redial = try #require(await rig.mesh.spoolRedial(MeshOnStub.relay))
            let curve = SpoolBackoff.waitMilliseconds(failures: 1)
            #expect((now + curve)..<(now + curve + SpoolBackoff.jitterMilliseconds) ~= redial, "the next dial follows the curve")
        }

        /// A socket whose receive never ends: the relay sends no `hello`, so at the handshake's 20 s the plane ends the session
        /// and the connection goes.
        @Test func aRelayThatNeverSaysHelloIsDroppedAtTheHandshake() async throws {
            let stub = try #require(StubServer([.upgrade(headers: [], steps: [])]))
            defer { stub.stop() }
            let rig = try await MeshOnStub.make(stub.url())
            #expect(await rig.eventually { await $0.spoolStatus.relays.first?.state == "open" }, "the socket opened")
            rig.clock.advance(SpoolSession.handshakeMilliseconds)
            #expect(await stub.ended(0, within: Self.tick) != nil, "the stub saw the connection end")
            #expect(await rig.eventually { await $0.spoolTasks.running.isEmpty }, "no task is left")
            let status = try #require(await rig.relayStatus())
            #expect(status.counts["sessions"] == 1 && status.counts["unreached"] == 1, "\(status)")
        }

        /// A full spool's `Retry-After` floors the next dial.
        @Test func aRetryAfterFloorsTheNextDial() async throws {
            let stub = try #require(StubServer([.http(status: 503, headers: [("Retry-After", Array("45".utf8))])]))
            defer { stub.stop() }
            let rig = try await MeshOnStub.make(stub.url())
            #expect(await rig.eventually { await $0.spoolStatus.relays.first?.counts["dialFailures"] == 1 })
            let now = rig.clock.monotonicMilliseconds()
            let redial = try #require(await rig.mesh.spoolRedial(MeshOnStub.relay))
            #expect(redial >= now + 45_000 && redial < now + 45_000 + SpoolBackoff.jitterMilliseconds, "floored at 45 s")
            #expect(rig.factory.failures.first?.status == 503)
        }

        struct Refusal: Sendable, CustomTestStringConvertible {
            let code: UInt16
            var testDescription: String { "\(code)" }
        }

        /// A 4001 or a 4003 reaches the plane as that code, and the session counts as unreached.
        @Test(arguments: [Refusal(code: 4001), Refusal(code: 4003)])
        func aRefusingCloseReachesThePlaneAsItsCode(_ refusal: Refusal) async throws {
            let reason = Array("a reason the plane never reads".utf8)
            let stub = try #require(StubServer([.upgrade(headers: [], steps: [.close(code: refusal.code, reason: reason)])]))
            defer { stub.stop() }
            let rig = try await MeshOnStub.make(stub.url())
            #expect(await rig.eventually { await $0.spoolStatus.relays.first?.counts["unreached"] == 1 })
            #expect(rig.factory.messages == [.closed(SpoolSocketEnd(.closed, code: Int(refusal.code)))])
            let status = try #require(await rig.relayStatus())
            #expect(status.counts["reached"] == 0 && status.counts["sessions"] == 1, "\(status)")
        }

        /// A dial whose address carries a marker in its query, refused by the address check, failing at once and failing
        /// after an upgrade: the marker reaches no failure, no end, no `status` and no log line, and the check's refusal is its
        /// one constant line.
        @Test func theAddressReachesNoFailureEndStatusOrLogLine() async throws {
            let marker = "zq9spoolmarker"
            let closed = try #require(StubServer([.silence]))
            let port = closed.port
            closed.stop()
            let checked = try await MeshOnStub.make("ws://127.0.0.1:0\(port)/spool/v1?x=\(marker)")
            #expect(await checked.eventually { await $0.spoolStatus.relays.first?.counts["dialFailures"] == 1 })
            #expect(checked.log.lines.contains("warning \(URLSessionSpoolSocketFactory.refusedLine)"), "the check's refusal")
            let refused = try await MeshOnStub.make("ws://127.0.0.1:\(port)/spool/v1?x=\(marker)")
            #expect(await refused.eventually { await $0.spoolStatus.relays.first?.counts["dialFailures"] == 1 })
            #expect(!refused.log.lines.contains("warning \(URLSessionSpoolSocketFactory.refusedLine)"), "the check took it")
            let stub = try #require(StubServer([.upgrade(headers: [], steps: [.close(code: 4001, reason: Array(marker.utf8))])]))
            defer { stub.stop() }
            let closing = try await MeshOnStub.make(stub.url(query: "x=\(marker)"))
            #expect(await closing.eventually { await $0.spoolStatus.relays.first?.counts["unreached"] == 1 })
            for rig in [checked, refused, closing] {
                var shown = rig.factory.failures.map { "\($0)" } + rig.factory.messages.map { "\($0)" } + rig.log.lines
                var dumped = ""
                dump(await rig.mesh.spoolStatus, to: &dumped)
                dump(rig.factory.failures, to: &dumped)
                dump(rig.factory.messages, to: &dumped)
                shown.append(dumped)
                for line in shown {
                    #expect(!line.contains(marker) && !line.contains("x="), "\(line)")
                }
            }
        }
    }
#endif
