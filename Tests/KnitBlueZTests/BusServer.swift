#if os(Linux)
    import CDBus
    import Glibc
    @testable import KnitBlueZ

    /// A libdbus server on a temporary Unix socket: the other end of a peer-to-peer ``BusConnection``, so a test can
    /// play BlueZ with no bus daemon. It is pumped by hand, on the test's thread, like the loop it talks to.
    final class BusServer {
        private let raw: OpaquePointer
        private var watches: [OpaquePointer] = []
        /// The connections accepted so far, oldest first.
        private(set) var connections: [BusConnection] = []
        /// Where a client connects.
        let address: String

        init() throws {
            var error = DBusError()
            dbus_error_init(&error)
            defer { dbus_error_free(&error) }
            guard let listening = dbus_server_listen("unix:tmpdir=/tmp", &error), let text = dbus_server_get_address(listening) else {
                throw BusError.unreachable(error.message.map { String(cString: $0) } ?? "no server")
            }
            raw = listening
            address = String(cString: text)
            dbus_free(text)
            let context = Unmanaged.passUnretained(self).toOpaque()
            dbus_server_set_watch_functions(raw, addWatch, removeWatch, nil, context, nil)
            dbus_server_set_new_connection_function(raw, newConnection, context, nil)
        }

        deinit {
            connections.removeAll()
            dbus_server_disconnect(raw)
            dbus_server_unref(raw)
        }

        /// Waits up to `waitMilliseconds` for anything to arrive, accepts whoever is connecting, then pumps every
        /// accepted connection once.
        func iterate(waitMilliseconds: Int32 = 0) {
            let enabled = watches.filter { dbus_watch_get_enabled($0) != 0 }
            var descriptors = enabled.map { pollfd(fd: dbus_watch_get_unix_fd($0), events: Int16(POLLIN), revents: 0) }
            descriptors += connections.compactMap(\.fileDescriptor).map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            _ = poll(&descriptors, nfds_t(descriptors.count), waitMilliseconds)
            for (watch, descriptor) in zip(enabled, descriptors) where descriptor.revents != 0 {
                dbus_watch_handle(watch, DBUS_WATCH_READABLE.rawValue)
            }
            for connection in connections {
                connection.pump(now: Monotonic.milliseconds())
            }
        }

        func added(_ watch: OpaquePointer) {
            watches.append(watch)
        }

        func removed(_ watch: OpaquePointer) {
            watches.removeAll { $0 == watch }
        }

        func accepted(_ connection: OpaquePointer) {
            connections.append(BusConnection(adopting: dbus_connection_ref(connection)))
        }
    }

    private func server(_ context: UnsafeMutableRawPointer?) -> BusServer? {
        context.map { Unmanaged<BusServer>.fromOpaque($0).takeUnretainedValue() }
    }

    private let addWatch: DBusAddWatchFunction = { watch, context in
        if let watch {
            server(context)?.added(watch)
        }
        return 1
    }

    private let removeWatch: DBusRemoveWatchFunction = { watch, context in
        if let watch {
            server(context)?.removed(watch)
        }
    }

    private let newConnection: DBusNewConnectionFunction = { _, connection, context in
        if let connection {
            server(context)?.accepted(connection)
        }
    }
#endif
