import KnitMesh
import KnitStore
import KnitWire
public import Observation

/// The user's own profile's view model: the name, status and open-to-chat flag peers read, and this device's
/// node id and alias.
@preconcurrency
@MainActor
@Observable
public final class OwnProfileModel {
    /// How near its limit the name field starts saying what is left.
    public static let nameWarnWithin = 8
    /// How near its limit the status field starts saying what is left.
    public static let statusWarnWithin = 20

    @ObservationIgnored private let session: AppSession
    private var nameText: String
    private var statusText: String
    /// Whether to invite DMs from people not met yet.
    public var openToChat: Bool
    private var saved: Saved

    private struct Saved: Equatable {
        var name: String
        var status: String
        var openToChat: Bool
    }

    /// The profile over `session`, loaded from what it last published.
    public init(session: AppSession) {
        self.session = session
        let own = session.stores.ownProfile.load()
        nameText = own.name
        statusText = own.status
        openToChat = own.openToChat
        saved = Saved(name: own.name, status: own.status, openToChat: own.openToChat)
    }

    /// The display name as typed, cut at ``TextLimits/displayName`` UTF-16 units.
    public var name: String {
        get { nameText }
        set { nameText = TextLimits.truncated(newValue, toUTF16: TextLimits.displayName) }
    }

    /// The status as typed, cut at ``TextLimits/status`` UTF-16 units.
    public var status: String {
        get { statusText }
        set { statusText = TextLimits.truncated(newValue, toUTF16: TextLimits.status) }
    }

    /// The name field's placeholder: the alias people see while the name is blank.
    public var alias: String {
        session.identity.alias
    }

    /// This device's node id.
    public var nodeId: String {
        session.identity.nodeId.string
    }

    /// Room left in the name, once it nears the limit.
    public var nameRemaining: Int? {
        Self.remaining(nameText, limit: TextLimits.displayName, within: Self.nameWarnWithin)
    }

    /// Room left in the status, once it nears the limit.
    public var statusRemaining: Int? {
        Self.remaining(statusText, limit: TextLimits.status, within: Self.statusWarnWithin)
    }

    /// Whether anything differs from what was last published.
    public var hasChanges: Bool {
        edited != saved
    }

    /// Publishes the profile, normalized the way every peer reads it.
    public func save() async {
        let profile = edited
        await session.updateProfile(name: profile.name, status: profile.status, openToChat: profile.openToChat)
        nameText = profile.name
        statusText = profile.status
        saved = profile
    }

    private var edited: Saved {
        Saved(
            name: Composer.singleLine(nameText, limit: TextLimits.displayName),
            status: Composer.singleLine(statusText, limit: TextLimits.status),
            openToChat: openToChat
        )
    }

    private static func remaining(_ text: String, limit: Int, within: Int) -> Int? {
        let left = limit - text.utf16.count
        return left <= within ? max(left, 0) : nil
    }
}
