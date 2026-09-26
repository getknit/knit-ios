#if os(Linux)
    import CDBus

    /// A private libdbus connection that never blocks: its owner polls ``fileDescriptor``, then calls ``pump(now:)``,
    /// which reads, writes and dispatches whatever is ready.
    ///
    /// It is confined to the thread that pumps it, and every handler runs on that thread, inside ``pump(now:)``.
    /// Calls are answered through a reply handler matched by serial, and time out on the owner's clock, because
    /// libdbus times out a pending call only for a connection wired to a main loop, which this one is not.
    internal final class BusConnection {
        /// Where to connect.
        enum Address: Equatable, Sendable {
            /// The system bus, where BlueZ lives.
            case system
            /// A peer-to-peer connection to a libdbus server: the tests' fake BlueZ.
            case peer(String)
        }

        /// What an exported object answers a method call with.
        enum Answer {
            /// A success reply carrying these arguments.
            case values([DBusValue])
            /// A D-Bus error reply.
            case error(name: String, message: String)
            /// The handler answers later, through ``reply(to:with:)`` or ``reply(to:error:message:)``.
            case later
            /// Not a method this object has: libdbus replies `UnknownMethod`.
            case unknown
        }

        typealias ReplyHandler = (Result<BusMessage, BusError>) -> Void
        typealias MethodHandler = (BusMessage) -> Answer
        typealias SignalHandler = (BusMessage) -> Void

        /// How long a call waits for its answer, as libdbus's own default does.
        static let defaultTimeoutMilliseconds: Int64 = 25_000
        static let failedError = "org.freedesktop.DBus.Error.Failed"

        private struct SignalKey: Hashable {
            let interface: String
            let member: String
        }

        private struct Pending {
            let deadline: Int64
            let handler: ReplyHandler
        }

        private let raw: OpaquePointer
        private var pending: [UInt32: Pending] = [:]
        private var objects: [String: MethodHandler] = [:]
        private var signals: [SignalKey: SignalHandler] = [:]
        /// Answers method calls to paths nothing exported: the fake BlueZ's objects.
        var fallback: MethodHandler?
        /// Runs once when the connection closes.
        var onDisconnect: (() -> Void)?
        /// Whether the connection is still open.
        private(set) var isOpen = true

        /// Opens a connection. The system bus registers with the bus daemon, which blocks for one round trip.
        convenience init(_ address: Address) throws(BusError) {
            var error = DBusError()
            dbus_error_init(&error)
            defer { dbus_error_free(&error) }
            let connection =
                switch address {
                case .system:
                    dbus_bus_get_private(DBUS_BUS_SYSTEM, &error)
                case .peer(let peer):
                    dbus_connection_open_private(peer, &error)
                }
            guard let connection else {
                throw .unreachable(error.message.map { String(cString: $0) } ?? "no reason given")
            }
            self.init(adopting: connection)
        }

        /// Takes over a private connection the caller holds one reference to.
        init(adopting raw: OpaquePointer) {
            self.raw = raw
            dbus_connection_set_exit_on_disconnect(raw, 0)
            dbus_connection_add_filter(raw, busFilter, Unmanaged.passUnretained(self).toOpaque(), nil)
        }

        deinit {
            dbus_connection_remove_filter(raw, busFilter, Unmanaged.passUnretained(self).toOpaque())
            dbus_connection_close(raw)
            dbus_connection_unref(raw)
        }

        // MARK: Polling

        /// The socket to poll, while the connection is open.
        var fileDescriptor: Int32? {
            var descriptor: Int32 = -1
            guard isOpen, dbus_connection_get_unix_fd(raw, &descriptor) != 0 else {
                return nil
            }
            return descriptor
        }

        /// Whether messages are waiting to be written, so the socket should be polled for writing too.
        var wantsToWrite: Bool {
            isOpen && dbus_connection_has_messages_to_send(raw) != 0
        }

        /// The earliest deadline of a call still waiting for its answer.
        var nextDeadline: Int64? {
            pending.values.map(\.deadline).min()
        }

        /// Reads and writes what the socket allows without blocking, runs a handler for everything that arrived,
        /// and times out calls whose deadline has passed.
        func pump(now: Int64) {
            guard isOpen else {
                return
            }
            dbus_connection_read_write(raw, 0)
            while isOpen, dbus_connection_dispatch(raw) == DBUS_DISPATCH_DATA_REMAINS {
                continue
            }
            if isOpen, dbus_connection_get_is_connected(raw) == 0 {
                closed()
            }
            expire(now: now)
        }

        /// Fails every call whose deadline is `now` or earlier.
        func expire(now: Int64) {
            let due = pending.filter { $0.value.deadline <= now }.keys.sorted()
            for serial in due {
                pending.removeValue(forKey: serial)?.handler(.failure(.timedOut))
            }
        }

        // MARK: Sending

        /// Sends a method call that waits ``defaultTimeoutMilliseconds`` for its answer.
        func call(_ message: BusMessage, now: Int64, reply: @escaping ReplyHandler) {
            call(message, now: now, timeoutMilliseconds: Self.defaultTimeoutMilliseconds, reply: reply)
        }

        /// Sends a method call; `reply` runs with the answer, an error, a timeout or a disconnect.
        func call(_ message: BusMessage, now: Int64, timeoutMilliseconds: Int64, reply: @escaping ReplyHandler) {
            var serial: UInt32 = 0
            guard isOpen, dbus_connection_send(raw, message.raw, &serial) != 0 else {
                reply(.failure(.disconnected))
                return
            }
            pending[serial] = Pending(deadline: now + timeoutMilliseconds, handler: reply)
        }

        /// Sends a message nobody answers: a signal, a reply, or a call whose answer does not matter.
        func send(_ message: BusMessage) {
            guard isOpen else {
                return
            }
            dbus_connection_send(raw, message.raw, nil)
        }

        /// Answers `call` with `values`, or with an error if they cannot be sent.
        func reply(to call: BusMessage, with values: [DBusValue]) {
            guard call.expectsReply, let reply = call.methodReturn() else {
                return
            }
            do {
                try reply.append(values)
                send(reply)
            } catch {
                self.reply(to: call, error: Self.failedError, message: "\(error)")
            }
        }

        /// Answers `call` with a D-Bus error.
        func reply(to call: BusMessage, error name: String, message: String) {
            guard call.expectsReply, let reply = call.errorReply(name: name, message: message) else {
                return
            }
            send(reply)
        }

        // MARK: Receiving

        /// Asks the bus daemon to route signals matching `rule` here, without waiting for its answer.
        func addMatch(_ rule: String) {
            guard isOpen, !rule.utf8.contains(0) else {
                return
            }
            dbus_bus_add_match(raw, rule, nil)
        }

        /// Runs `handler` for every signal `interface.member` that reaches this connection.
        func onSignal(interface: String, member: String, _ handler: @escaping SignalHandler) {
            signals[SignalKey(interface: interface, member: member)] = handler
        }

        /// Answers method calls to `path` with `handler`.
        func export(_ path: String, _ handler: @escaping MethodHandler) {
            objects[path] = handler
        }

        /// Stops answering method calls to `path`.
        func unexport(_ path: String) {
            objects[path] = nil
        }

        /// Runs whatever handler `message` is for. Only the filter calls this.
        func dispatch(_ message: BusMessage) -> DBusHandlerResult {
            switch message.kind {
            case .methodReturn, .error:
                guard let waiting = pending.removeValue(forKey: message.replySerial) else {
                    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED
                }
                if message.kind == .error {
                    let text = (try? message.arguments())?.first?.text ?? ""
                    waiting.handler(.failure(.remote(name: message.errorName ?? Self.failedError, message: text)))
                } else {
                    waiting.handler(.success(message))
                }
                return DBUS_HANDLER_RESULT_HANDLED
            case .signal:
                if message.interface == "org.freedesktop.DBus.Local", message.member == "Disconnected" {
                    closed()
                    return DBUS_HANDLER_RESULT_HANDLED
                }
                guard let interface = message.interface, let member = message.member,
                    let handler = signals[SignalKey(interface: interface, member: member)]
                else {
                    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED
                }
                handler(message)
                return DBUS_HANDLER_RESULT_HANDLED
            case .methodCall:
                guard let handler = message.path.flatMap({ objects[$0] }) ?? fallback else {
                    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED
                }
                return answer(message, with: handler(message))
            case .other:
                return DBUS_HANDLER_RESULT_NOT_YET_HANDLED
            }
        }

        private func answer(_ call: BusMessage, with answer: Answer) -> DBusHandlerResult {
            switch answer {
            case .values(let values):
                reply(to: call, with: values)
            case .error(let name, let text):
                reply(to: call, error: name, message: text)
            case .later:
                break
            case .unknown:
                return DBUS_HANDLER_RESULT_NOT_YET_HANDLED
            }
            return DBUS_HANDLER_RESULT_HANDLED
        }

        /// Closes the connection now; waiting calls fail as disconnected.
        func close() {
            guard isOpen else {
                return
            }
            dbus_connection_close(raw)
            closed()
        }

        private func closed() {
            guard isOpen else {
                return
            }
            isOpen = false
            let waiting = pending.sorted { $0.key < $1.key }.map(\.value.handler)
            pending.removeAll()
            for handler in waiting {
                handler(.failure(.disconnected))
            }
            onDisconnect?()
        }
    }

    /// The one filter every ``BusConnection`` installs, with the connection as its context. A C function pointer
    /// captures nothing, which is why the connection travels as an unretained pointer; it removes the filter in
    /// `deinit`, before the pointer could dangle.
    private let busFilter: DBusHandleMessageFunction = { _, message, context in
        guard let message, let context else {
            return DBUS_HANDLER_RESULT_NOT_YET_HANDLED
        }
        let connection = Unmanaged<BusConnection>.fromOpaque(context).takeUnretainedValue()
        return connection.dispatch(BusMessage(retaining: message))
    }
#endif
