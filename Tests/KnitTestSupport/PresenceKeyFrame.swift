public import KnitWire

extension PresenceKeyFrame {
    /// The padded content handing over `keys`, one key or two with the higher generation as the next pair, lowest generation
    /// first, as Android's `content(keys)` takes them (`mesh/crypto/PresenceKeyFrame.kt:34-64` at knit-next `cad69c77b`):
    /// for the tests that hand an iPhone a contact's keys.
    public static func content(_ keys: [(generation: Int64, key: [UInt8])]) -> MessageContent {
        precondition((1...2).contains(keys.count), "a presence-key frame carries one or two keys")
        return content(current: keys[0], next: keys.count > 1 ? keys[1] : nil)
    }
}
