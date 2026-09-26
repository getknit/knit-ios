#if os(Linux)
    import CDBus

    /// Why a D-Bus exchange failed.
    internal enum BusError: Error, Equatable, Sendable {
        /// The bus could not be reached, with libdbus's reason.
        case unreachable(String)
        /// A name, path or value that libdbus would refuse by aborting the process.
        case malformed(String)
        /// The other side answered with a D-Bus error.
        case remote(name: String, message: String)
        /// No answer before the deadline.
        case timedOut
        /// The connection closed before the answer came.
        case disconnected
    }

    /// One libdbus message, owned: the reference is released when this goes.
    ///
    /// Every factory checks its names first, since libdbus aborts on a malformed one, and ``append(_:)`` checks the
    /// values. Reading never aborts: libdbus has already validated a message that arrived.
    internal final class BusMessage {
        /// libdbus's `DBUS_MESSAGE_TYPE_*`.
        enum Kind: Equatable {
            case methodCall
            case methodReturn
            case error
            case signal
            case other
        }

        let raw: OpaquePointer

        /// Takes over a reference the caller already holds, as every `dbus_message_new_*` returns one.
        init(adopting raw: OpaquePointer) {
            self.raw = raw
        }

        /// Takes a new reference to a message libdbus lends, as a filter receives one.
        init(retaining raw: OpaquePointer) {
            self.raw = dbus_message_ref(raw)
        }

        deinit {
            dbus_message_unref(raw)
        }

        // MARK: Making messages

        /// A method call, or `nil` when a name is malformed.
        static func methodCall(destination: String?, path: String, interface: String, member: String) -> BusMessage? {
            guard destination.map(DBusNames.isBusName) ?? true, DBusNames.isObjectPath(path), DBusNames.isInterface(interface),
                DBusNames.isMember(member), let made = dbus_message_new_method_call(destination, path, interface, member)
            else {
                return nil
            }
            return BusMessage(adopting: made)
        }

        /// The success reply to this call, or `nil` for a call never sent: libdbus aborts on a reply to serial 0.
        func methodReturn() -> BusMessage? {
            guard serial != 0 else {
                return nil
            }
            return dbus_message_new_method_return(raw).map(Self.init(adopting:))
        }

        /// An error reply to this call, or `nil` for a call never sent or a malformed name.
        func errorReply(name: String, message: String) -> BusMessage? {
            guard serial != 0, DBusNames.isErrorName(name), !message.utf8.contains(0),
                let reply = dbus_message_new_error(raw, name, message)
            else {
                return nil
            }
            return BusMessage(adopting: reply)
        }

        // MARK: Headers

        var kind: Kind {
            switch dbus_message_get_type(raw) {
            case DBUS_MESSAGE_TYPE_METHOD_CALL:
                .methodCall
            case DBUS_MESSAGE_TYPE_METHOD_RETURN:
                .methodReturn
            case DBUS_MESSAGE_TYPE_ERROR:
                .error
            case DBUS_MESSAGE_TYPE_SIGNAL:
                .signal
            default:
                .other
            }
        }

        var path: String? { dbus_message_get_path(raw).map { String(cString: $0) } }
        var interface: String? { dbus_message_get_interface(raw).map { String(cString: $0) } }
        var member: String? { dbus_message_get_member(raw).map { String(cString: $0) } }
        var errorName: String? { dbus_message_get_error_name(raw).map { String(cString: $0) } }
        var sender: String? { dbus_message_get_sender(raw).map { String(cString: $0) } }
        var serial: UInt32 { dbus_message_get_serial(raw) }
        var replySerial: UInt32 { dbus_message_get_reply_serial(raw) }
        var expectsReply: Bool { dbus_message_get_no_reply(raw) == 0 }

        // MARK: Arguments

        /// Appends `values` as the message's arguments, or throws before touching the message when one is
        /// malformed.
        func append(_ values: [DBusValue]) throws(BusError) {
            guard let bad = values.first(where: { !$0.isWellFormed }) else {
                var iter = DBusMessageIter()
                dbus_message_iter_init_append(raw, &iter)
                for value in values where !Self.append(value, to: &iter) {
                    throw .malformed("libdbus refused \(value.type.signature)")
                }
                return
            }
            throw .malformed("argument of type \(bad.type.signature)")
        }

        /// Appends one argument.
        func append(_ value: DBusValue) throws(BusError) {
            try append([value])
        }

        /// The message's arguments, in order.
        func arguments() throws(BusError) -> [DBusValue] {
            var iter = DBusMessageIter()
            guard dbus_message_iter_init(raw, &iter) != 0 else {
                return []
            }
            var values: [DBusValue] = []
            repeat {
                values.append(try Self.read(&iter))
            } while dbus_message_iter_next(&iter) != 0
            return values
        }
    }
#endif
