import KnitWire

/// A per-device tag that keeps a block in place when a blocked person makes new keys (`DeviceTag.kt`).
///
/// A new key pair means a new node id, but the same device gives the same tag. The tag is self-asserted, so it
/// deters and never proves: nothing routes, addresses or trusts by it.
public enum DeviceTag {
    private static let salt = "knit-device-tag-v1:"
    private static let tagByteCount = 8

    /// The 16-hex-digit tag for a stable device identifier, or `nil` when there is none or it is blank.
    public static func derive(_ rawDeviceId: String?) -> String? {
        guard let rawDeviceId, !TextLimits.isBlank(rawDeviceId) else {
            return nil
        }
        return Hex.encode(Array(sha256(salt + rawDeviceId).prefix(tagByteCount)))
    }
}
