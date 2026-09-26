/// The D-Bus specification's naming rules, checked before anything reaches libdbus: libdbus answers a malformed
/// name by aborting the process, and a device path from BlueZ or a node id in an object path must never do that.
internal enum DBusNames {
    private static let maximumLength = 255
    /// An interface, error or bus name has at least two elements: `org.bluez`.
    private static let minimumElements = 2

    /// `/`, or `/`-separated elements of `[A-Za-z0-9_]`, with no empty element and no trailing slash.
    static func isObjectPath(_ path: String) -> Bool {
        guard path.first == "/" else {
            return false
        }
        if path == "/" {
            return true
        }
        let elements = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        return elements.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy(isElementByte) }
    }

    /// Two or more `.`-separated elements, each an identifier that does not start with a digit.
    static func isInterface(_ name: String) -> Bool {
        let elements = name.split(separator: ".", omittingEmptySubsequences: false)
        return name.utf8.count <= maximumLength && elements.count >= minimumElements && elements.allSatisfy { isIdentifier($0) }
    }

    /// An error name follows the interface rules.
    static func isErrorName(_ name: String) -> Bool {
        isInterface(name)
    }

    /// One identifier that does not start with a digit.
    static func isMember(_ name: String) -> Bool {
        name.utf8.count <= maximumLength && isIdentifier(Substring(name))
    }

    /// A unique name (`:1.42`) or a well-known one (`org.bluez`). Hyphens are allowed in both.
    static func isBusName(_ name: String) -> Bool {
        guard name.utf8.count <= maximumLength else {
            return false
        }
        let unique = name.first == ":"
        let elements = (unique ? name.dropFirst() : Substring(name)).split(separator: ".", omittingEmptySubsequences: false)
        return elements.count >= minimumElements
            && elements.allSatisfy { element in
                guard let first = element.utf8.first, element.utf8.allSatisfy({ isElementByte($0) || $0 == UInt8(ascii: "-") }) else {
                    return false
                }
                return unique || !isDigit(first)
            }
    }

    /// A signature: any number of complete types, 255 bytes at most.
    static func isSignature(_ text: String) -> Bool {
        guard text.utf8.count <= maximumLength else {
            return false
        }
        var rest = Substring(text)
        while !rest.isEmpty {
            guard let (_, remainder) = DBusType.parseLeading(rest) else {
                return false
            }
            rest = remainder
        }
        return true
    }

    private static func isIdentifier(_ text: Substring) -> Bool {
        guard let first = text.utf8.first, !isDigit(first) else {
            return false
        }
        return text.utf8.allSatisfy(isElementByte)
    }

    private static func isElementByte(_ byte: UInt8) -> Bool {
        isDigit(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || byte == UInt8(ascii: "_")
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
}
