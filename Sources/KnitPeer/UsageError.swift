/// Whether knit-peer reads GATT payloads, and so sets `FLAG_DIALS_GATT_PEERS` (`--gatt-reads`, `--no-gatt-reads`).
public enum GattReads: Equatable, Sendable {
    /// As the radio profile does: the `ios` profile reads, and the `android` profile does not.
    case asProfile
    /// Reads, whatever the profile.
    case on
    /// Reads nothing, whatever the profile.
    case off
}

/// Why the arguments did not parse.
public enum UsageError: Error, Equatable, Sendable {
    /// Not `run`, `keygen` or `help`.
    case unknownCommand(String)
    /// A flag this command does not take.
    case unknownFlag(String)
    /// A flag with no value after it.
    case missingValue(String)
    /// A value a flag does not accept.
    case invalid(flag: String, value: String)
    /// A flag given twice.
    case repeated(String)
    /// Something required that was not given.
    case missing(String)
}

/// The `--flag value` pairs and the valueless `switches`, taken one by one so that whatever is left over is an error.
internal struct Flags {
    private var values: [String: String] = [:]

    init(parsing arguments: ArraySlice<String>, switches: Set<String>) throws(UsageError) {
        var rest = arguments
        while let flag = rest.popFirst() {
            guard flag.hasPrefix("--") else {
                throw .unknownFlag(flag)
            }
            var value = ""
            if !switches.contains(flag) {
                guard let next = rest.popFirst(), !next.hasPrefix("--") else {
                    throw .missingValue(flag)
                }
                value = next
            }
            guard values.updateValue(value, forKey: flag) == nil else {
                throw .repeated(flag)
            }
        }
    }

    mutating func take(_ flag: String) -> String? {
        values.removeValue(forKey: flag)
    }

    /// Whether the switch `flag` was given.
    mutating func take(switch flag: String) -> Bool {
        values.removeValue(forKey: flag) != nil
    }

    mutating func take(_ flag: String, oneOf allowed: [String]) throws(UsageError) -> String? {
        guard let value = values.removeValue(forKey: flag) else {
            return nil
        }
        guard allowed.contains(value) else {
            throw .invalid(flag: flag, value: value)
        }
        return value
    }

    func finish() throws(UsageError) {
        if let flag = values.keys.min() {
            throw .unknownFlag(flag)
        }
    }
}
