#if os(Linux)
    import CDBus
    @testable import KnitBlueZ

    /// Signals, which only BlueZ sends: the fake BlueZ emits them, and the radio never does.
    extension BusMessage {
        /// A signal, or `nil` when a name is malformed.
        static func signal(path: String, interface: String, member: String) -> BusMessage? {
            guard DBusNames.isObjectPath(path), DBusNames.isInterface(interface), DBusNames.isMember(member),
                let made = dbus_message_new_signal(path, interface, member)
            else {
                return nil
            }
            return BusMessage(adopting: made)
        }
    }

    extension BusConnection {
        /// Emits a signal from `path`.
        func emit(path: String, interface: String, member: String, values: [DBusValue]) throws(BusError) {
            guard let signal = BusMessage.signal(path: path, interface: interface, member: member) else {
                throw .malformed("signal \(interface).\(member) on \(path)")
            }
            try signal.append(values)
            send(signal)
        }
    }
#endif
