#if os(Linux)
    import CDBus

    /// Moving ``DBusValue``s in and out of libdbus's message iterators.
    extension BusMessage {
        static func append(_ value: DBusValue, to iter: inout DBusMessageIter) -> Bool {
            switch value {
            case .byte(var byte):
                return dbus_message_iter_append_basic(&iter, Int32(TypeCode.byte), &byte) != 0
            case .boolean(let flag):
                var bool: dbus_bool_t = flag ? 1 : 0
                return dbus_message_iter_append_basic(&iter, Int32(TypeCode.boolean), &bool) != 0
            case .int16(var number):
                return dbus_message_iter_append_basic(&iter, Int32(TypeCode.int16), &number) != 0
            case .uint16(var number):
                return dbus_message_iter_append_basic(&iter, Int32(TypeCode.uint16), &number) != 0
            case .int32(var number):
                return dbus_message_iter_append_basic(&iter, Int32(TypeCode.int32), &number) != 0
            case .uint32(var number):
                return dbus_message_iter_append_basic(&iter, Int32(TypeCode.uint32), &number) != 0
            case .int64(var number):
                return dbus_message_iter_append_basic(&iter, Int32(TypeCode.int64), &number) != 0
            case .uint64(var number):
                return dbus_message_iter_append_basic(&iter, Int32(TypeCode.uint64), &number) != 0
            case .double(var number):
                return dbus_message_iter_append_basic(&iter, Int32(TypeCode.double), &number) != 0
            case .string(let text), .objectPath(let text), .signature(let text):
                return text.withCString { cString in
                    var pointer: UnsafePointer<CChar>? = cString
                    return dbus_message_iter_append_basic(&iter, Int32(value.type.code), &pointer) != 0
                }
            case .bytes(let bytes):
                return container(TypeCode.array, "y", in: &iter) { sub in
                    bytes.isEmpty
                        || bytes.withUnsafeBufferPointer { buffer in
                            var base = buffer.baseAddress
                            return dbus_message_iter_append_fixed_array(&sub, Int32(TypeCode.byte), &base, Int32(buffer.count)) != 0
                        }
                }
            case .array(let element, let items):
                return container(TypeCode.array, element.signature, in: &iter) { sub in
                    items.allSatisfy { append($0, to: &sub) }
                }
            case .dictionary(let key, let valueType, let entries):
                return container(TypeCode.array, "{" + key.signature + valueType.signature + "}", in: &iter) { sub in
                    entries.allSatisfy { entry in
                        container(TypeCode.dictionaryEntry, nil, in: &sub) { pair in
                            append(entry.key, to: &pair) && append(entry.value, to: &pair)
                        }
                    }
                }
            case .variant(let inner):
                return container(TypeCode.variant, inner.type.signature, in: &iter) { append(inner, to: &$0) }
            case .structure(let fields):
                return container(TypeCode.structure, nil, in: &iter) { sub in fields.allSatisfy { append($0, to: &sub) } }
            }
        }

        /// Opens a container, fills it, and closes it, or abandons it when filling fails.
        private static func container(
            _ code: UInt8,
            _ signature: String?,
            in iter: inout DBusMessageIter,
            fill: (inout DBusMessageIter) -> Bool
        ) -> Bool {
            var sub = DBusMessageIter()
            let opened =
                signature.map { text in text.withCString { dbus_message_iter_open_container(&iter, Int32(code), $0, &sub) } }
                ?? dbus_message_iter_open_container(&iter, Int32(code), nil, &sub)
            guard opened != 0 else {
                return false
            }
            guard fill(&sub) else {
                dbus_message_iter_abandon_container(&iter, &sub)
                return false
            }
            return dbus_message_iter_close_container(&iter, &sub) != 0
        }

        static func read(_ iter: inout DBusMessageIter) throws(BusError) -> DBusValue {
            let code = UInt8(truncatingIfNeeded: dbus_message_iter_get_arg_type(&iter))
            switch code {
            case TypeCode.byte:
                return .byte(basic(&iter, as: UInt8.self))
            case TypeCode.boolean:
                return .boolean(basic(&iter, as: dbus_bool_t.self) != 0)
            case TypeCode.int16:
                return .int16(basic(&iter, as: Int16.self))
            case TypeCode.uint16:
                return .uint16(basic(&iter, as: UInt16.self))
            case TypeCode.int32:
                return .int32(basic(&iter, as: Int32.self))
            case TypeCode.uint32:
                return .uint32(basic(&iter, as: UInt32.self))
            case TypeCode.int64:
                return .int64(basic(&iter, as: Int64.self))
            case TypeCode.uint64:
                return .uint64(basic(&iter, as: UInt64.self))
            case TypeCode.double:
                return .double(basic(&iter, as: Double.self))
            case TypeCode.string:
                return .string(text(&iter))
            case TypeCode.objectPath:
                return .objectPath(text(&iter))
            case TypeCode.signature:
                return .signature(text(&iter))
            case TypeCode.array:
                return try readArray(&iter)
            case TypeCode.variant:
                var sub = DBusMessageIter()
                dbus_message_iter_recurse(&iter, &sub)
                return .variant(try read(&sub))
            case TypeCode.structure:
                var sub = DBusMessageIter()
                dbus_message_iter_recurse(&iter, &sub)
                return .structure(try readAll(&sub))
            default:
                throw .malformed("unsupported type code \(code)")
            }
        }

        private static func readArray(_ iter: inout DBusMessageIter) throws(BusError) -> DBusValue {
            let element = UInt8(truncatingIfNeeded: dbus_message_iter_get_element_type(&iter))
            var sub = DBusMessageIter()
            dbus_message_iter_recurse(&iter, &sub)
            if element == TypeCode.byte {
                var base: UnsafeRawPointer?
                var count: Int32 = 0
                dbus_message_iter_get_fixed_array(&sub, &base, &count)
                guard let base, count > 0 else {
                    return .bytes([])
                }
                return .bytes(Array(UnsafeRawBufferPointer(start: base, count: Int(count))))
            }
            guard let spelled = dbus_message_iter_get_signature(&iter) else {
                throw .malformed("an array with no signature")
            }
            defer { dbus_free(spelled) }
            let text = String(cString: spelled)
            switch DBusType(signature: text) {
            case .dictionary(let key, let value):
                var entries: [DBusEntry] = []
                while dbus_message_iter_get_arg_type(&sub) != Int32(TypeCode.invalid) {
                    var pair = DBusMessageIter()
                    dbus_message_iter_recurse(&sub, &pair)
                    let entryKey = try read(&pair)
                    dbus_message_iter_next(&pair)
                    entries.append(DBusEntry(key: entryKey, value: try read(&pair)))
                    dbus_message_iter_next(&sub)
                }
                return .dictionary(key: key, value: value, entries)
            case .array(let elementType):
                return .array(elementType, try readAll(&sub))
            default:
                throw .malformed("an array typed \(text)")
            }
        }

        private static func readAll(_ iter: inout DBusMessageIter) throws(BusError) -> [DBusValue] {
            var values: [DBusValue] = []
            while dbus_message_iter_get_arg_type(&iter) != Int32(TypeCode.invalid) {
                values.append(try read(&iter))
                dbus_message_iter_next(&iter)
            }
            return values
        }

        private static func basic<Value: FixedWidthInteger>(_ iter: inout DBusMessageIter, as _: Value.Type) -> Value {
            var value: Value = 0
            dbus_message_iter_get_basic(&iter, &value)
            return value
        }

        private static func basic(_ iter: inout DBusMessageIter, as _: Double.Type) -> Double {
            var value = 0.0
            dbus_message_iter_get_basic(&iter, &value)
            return value
        }

        private static func text(_ iter: inout DBusMessageIter) -> String {
            var pointer: UnsafePointer<CChar>?
            dbus_message_iter_get_basic(&iter, &pointer)
            return pointer.map { String(cString: $0) } ?? ""
        }
    }
#endif
