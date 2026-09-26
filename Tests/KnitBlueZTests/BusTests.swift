#if os(Linux)
    @testable import KnitBlueZ
    import Testing

    /// libdbus messages and a peer-to-peer connection, with a ``BusServer`` on the far end.
    @Suite(.timeLimit(.minutes(1))) struct BusTests {
        // MARK: Messages

        @Test func everyValueRoundTripsThroughAMessage() throws {
            let values: [DBusValue] = [
                .byte(0xFE), .boolean(true), .boolean(false), .int16(-2), .uint16(0xFE30), .int32(-3), .uint32(4), .int64(-5), .uint64(6),
                .double(1.5), .string("knit"), .objectPath("/org/bluez/hci1"), .signature("a{sv}"), .bytes([1, 2, 3]), .bytes([]),
                .strings(["a", "b"]), .array(.string, []), .properties([("Type", .string("peripheral")), ("Data", .bytes([9]))]),
                .dictionary(key: .objectPath, value: .string, [DBusEntry(key: .objectPath("/a"), value: .string("x"))]),
                .variant(.variant(.int32(1))), .structure([.string("s"), .array(.variant, [.variant(.byte(1))])]),
            ]
            let message = try #require(
                BusMessage.methodCall(destination: "org.bluez", path: "/", interface: "org.example.Test", member: "Echo"))
            try message.append(values)
            #expect(try message.arguments() == values)
        }

        @Test func aMessageWithNoArgumentsReadsAsNone() throws {
            let message = try #require(BusMessage.signal(path: "/", interface: "org.example.Test", member: "Ping"))
            #expect(try message.arguments().isEmpty)
            #expect(message.kind == .signal)
            #expect(message.path == "/")
            #expect(message.interface == "org.example.Test")
            #expect(message.member == "Ping")
        }

        @Test func aMalformedArgumentIsRefusedAndTheMessageLeftAlone() throws {
            let message = try #require(BusMessage.methodCall(destination: nil, path: "/", interface: "org.example.Test", member: "Echo"))
            #expect(throws: BusError.malformed("argument of type o")) { try message.append([.string("ok"), .objectPath("bad")]) }
            #expect(try message.arguments().isEmpty)
        }

        @Test func malformedNamesMakeNoMessage() {
            #expect(BusMessage.methodCall(destination: "bad name", path: "/", interface: "org.example.Test", member: "Echo") == nil)
            #expect(BusMessage.methodCall(destination: nil, path: "relative", interface: "org.example.Test", member: "Echo") == nil)
            #expect(BusMessage.methodCall(destination: nil, path: "/", interface: "Test", member: "Echo") == nil)
            #expect(BusMessage.methodCall(destination: nil, path: "/", interface: "org.example.Test", member: "Ec.ho") == nil)
            #expect(BusMessage.signal(path: "/", interface: "Test", member: "Ping") == nil)
        }

        @Test func aCallNeverSentHasNoReply() throws {
            let call = try #require(BusMessage.methodCall(destination: nil, path: "/", interface: "org.example.Test", member: "Echo"))
            #expect(call.serial == 0)
            #expect(call.methodReturn() == nil, "libdbus would abort")
            #expect(call.errorReply(name: "org.example.Error.Failed", message: "no") == nil)
            #expect(call.expectsReply)
        }

        @Test func anErrorReplyNeedsAWellFormedName() throws {
            let pair = try Pair()
            pair.pump { pair.far != nil }
            var replies: [BusMessage?] = []
            try #require(pair.far).export("/obj") { call in
                replies = [
                    call.errorReply(name: "not an error", message: "x"),
                    call.errorReply(name: "org.example.Error.Failed", message: "a\u{0}b"),
                    call.errorReply(name: "org.example.Error.Failed", message: "no"),
                ]
                return .values([])
            }
            let call = try #require(BusMessage.methodCall(destination: nil, path: "/obj", interface: "org.example.Test", member: "Echo"))
            var answered = false
            pair.client.call(call, now: Monotonic.milliseconds()) { _ in answered = true }
            pair.pump { answered }
            #expect(replies.count == 3)
            #expect(replies.prefix(2).allSatisfy { $0 == nil })
            let reply = try #require(replies.compactMap(\.self).last)
            #expect(reply.kind == .error)
            #expect(reply.errorName == "org.example.Error.Failed")
            #expect(try reply.arguments() == [.string("no")])
        }

        // MARK: A connection

        /// A client connected to a fresh server, both pumped by hand.
        private struct Pair {
            let server: BusServer
            let client: BusConnection
            var far: BusConnection? { server.connections.first }

            init() throws {
                server = try BusServer()
                client = try BusConnection(.peer(server.address))
            }

            func pump(until condition: () -> Bool) {
                for _ in 0..<500 where !condition() {
                    client.pump(now: Monotonic.milliseconds())
                    server.iterate(waitMilliseconds: 1)
                }
            }
        }

        @Test func aCallIsAnswered() throws {
            let pair = try Pair()
            pair.pump { pair.far != nil }
            let far = try #require(pair.far)
            far.export("/echo") { call in .values((try? call.arguments()) ?? []) }
            let call = try #require(BusMessage.methodCall(destination: nil, path: "/echo", interface: "org.example.Test", member: "Echo"))
            try call.append(.string("hello"))
            var answer: [DBusValue]?
            pair.client.call(call, now: Monotonic.milliseconds()) { answer = try? $0.get().arguments() }
            #expect(pair.client.nextDeadline != nil)
            pair.pump { answer != nil }
            #expect(answer == [.string("hello")])
            #expect(pair.client.nextDeadline == nil)
        }

        @Test func aRemoteErrorCarriesItsNameAndText() throws {
            let pair = try Pair()
            pair.pump { pair.far != nil }
            try #require(pair.far).export("/fail") { _ in .error(name: "org.example.Error.Nope", message: "not today") }
            let call = try #require(BusMessage.methodCall(destination: nil, path: "/fail", interface: "org.example.Test", member: "Try"))
            var answer: Result<BusMessage, BusError>?
            pair.client.call(call, now: Monotonic.milliseconds()) { answer = $0 }
            pair.pump { answer != nil }
            #expect(throws: BusError.remote(name: "org.example.Error.Nope", message: "not today")) { try answer?.get() }
        }

        @Test func anUnknownMethodIsRefusedByLibdbus() throws {
            let pair = try Pair()
            pair.pump { pair.far != nil }
            try #require(pair.far).export("/obj") { _ in .unknown }
            var answers: [Result<BusMessage, BusError>] = []
            for path in ["/obj", "/nothing"] {
                let call = try #require(BusMessage.methodCall(destination: nil, path: path, interface: "org.example.Test", member: "Try"))
                pair.client.call(call, now: Monotonic.milliseconds()) { answers.append($0) }
            }
            pair.pump { answers.count == 2 }
            for answer in answers {
                #expect(throws: BusError.self) { try answer.get() }
            }
        }

        @Test func anAnswerGivenLaterArrives() throws {
            let pair = try Pair()
            pair.pump { pair.far != nil }
            let far = try #require(pair.far)
            var held: BusMessage?
            far.export("/slow") { call in
                held = call
                return .later
            }
            let call = try #require(BusMessage.methodCall(destination: nil, path: "/slow", interface: "org.example.Test", member: "Wait"))
            var answer: [DBusValue]?
            pair.client.call(call, now: Monotonic.milliseconds()) { answer = try? $0.get().arguments() }
            pair.pump { held != nil }
            far.reply(to: try #require(held), with: [.uint32(7)])
            pair.pump { answer != nil }
            #expect(answer == [.uint32(7)])
        }

        @Test func valuesThatCannotBeSentBecomeAnError() throws {
            let pair = try Pair()
            pair.pump { pair.far != nil }
            try #require(pair.far).export("/bad") { _ in .values([.objectPath("not a path")]) }
            let call = try #require(BusMessage.methodCall(destination: nil, path: "/bad", interface: "org.example.Test", member: "Get"))
            var answer: Result<BusMessage, BusError>?
            pair.client.call(call, now: Monotonic.milliseconds()) { answer = $0 }
            pair.pump { answer != nil }
            guard case .failure(.remote(let name, _)) = answer else {
                Issue.record("expected an error, got \(String(describing: answer))")
                return
            }
            #expect(name == BusConnection.failedError)
        }

        @Test func aCallNobodyAnswersTimesOut() throws {
            let pair = try Pair()
            pair.pump { pair.far != nil }
            try #require(pair.far).export("/void") { _ in .later }
            let call = try #require(BusMessage.methodCall(destination: nil, path: "/void", interface: "org.example.Test", member: "Wait"))
            var answer: Result<BusMessage, BusError>?
            let now = Monotonic.milliseconds()
            pair.client.call(call, now: now, timeoutMilliseconds: 50) { answer = $0 }
            pair.client.expire(now: now + 49)
            #expect(answer == nil)
            pair.client.expire(now: now + 50)
            #expect(throws: BusError.timedOut) { try answer?.get() }
        }

        @Test func signalsReachTheirHandlerAndOthersAreIgnored() throws {
            let pair = try Pair()
            pair.pump { pair.far != nil }
            var heard: [DBusValue] = []
            pair.client.onSignal(interface: "org.example.Test", member: "Tick") { heard += (try? $0.arguments()) ?? [] }
            pair.client.addMatch("type='signal'")
            pair.client.addMatch("bad\u{0}rule")
            let far = try #require(pair.far)
            try far.emit(path: "/", interface: "org.example.Test", member: "Tock", values: [.int32(0)])
            try far.emit(path: "/", interface: "org.example.Test", member: "Tick", values: [.int32(1)])
            pair.pump { !heard.isEmpty }
            #expect(heard == [.int32(1)])
            #expect(throws: BusError.self) { try far.emit(path: "bad", interface: "org.example.Test", member: "Tick", values: []) }
        }

        @Test func unexportingStopsTheAnswers() throws {
            let pair = try Pair()
            pair.pump { pair.far != nil }
            let far = try #require(pair.far)
            far.export("/gone") { _ in .values([]) }
            far.unexport("/gone")
            let call = try #require(BusMessage.methodCall(destination: nil, path: "/gone", interface: "org.example.Test", member: "Hi"))
            var answer: Result<BusMessage, BusError>?
            pair.client.call(call, now: Monotonic.milliseconds()) { answer = $0 }
            pair.pump { answer != nil }
            #expect(throws: BusError.self) { try answer?.get() }
        }

        @Test func closingFailsWhatWaitsAndTellsTheOwner() throws {
            let pair = try Pair()
            pair.pump { pair.far != nil }
            try #require(pair.far).export("/void") { _ in .later }
            var closed = false
            pair.client.onDisconnect = { closed = true }
            let call = try #require(BusMessage.methodCall(destination: nil, path: "/void", interface: "org.example.Test", member: "Wait"))
            var answer: Result<BusMessage, BusError>?
            pair.client.call(call, now: Monotonic.milliseconds()) { answer = $0 }
            pair.pump { pair.far?.wantsToWrite == false }
            try #require(pair.far).close()
            pair.pump { closed }
            #expect(throws: BusError.disconnected) { try answer?.get() }
            #expect(!pair.client.isOpen)
            #expect(pair.client.fileDescriptor == nil)
            var late: Result<BusMessage, BusError>?
            pair.client.call(call, now: Monotonic.milliseconds()) { late = $0 }
            #expect(throws: BusError.disconnected) { try late?.get() }
            pair.client.close()
            pair.client.send(call)
            pair.client.addMatch("type='signal'")
        }

        @Test func aServerThatIsNotThereIsUnreachable() {
            #expect(throws: BusError.self) { try BusConnection(.peer("unix:path=/nonexistent/knit-bus")) }
        }
    }
#endif
