import KnitSync

/// The app's own settings, which outlive a launch: UserDefaults in the app, memory in tests and `-seedDemo`.
public protocol AppPreferences: AnyObject, Sendable {
    /// Whether onboarding finished on this install.
    var hasOnboarded: Bool { get set }
    /// Whether someone else's explicit photos and faces hide: Content filtering, on until it is turned off.
    var filtersContent: Bool { get set }
}

/// ``AppPreferences`` in memory.
public final class MemoryPreferences: AppPreferences {
    private let onboarded: Lock<Bool>
    private let filters: Lock<Bool>

    /// Preferences starting from `hasOnboarded` and `filtersContent`.
    public init(hasOnboarded: Bool = false, filtersContent: Bool = true) {
        onboarded = Lock(hasOnboarded)
        filters = Lock(filtersContent)
    }

    public var hasOnboarded: Bool {
        get { onboarded.withLock { $0 } }
        set { onboarded.withLock { $0 = newValue } }
    }

    public var filtersContent: Bool {
        get { filters.withLock { $0 } }
        set { filters.withLock { $0 = newValue } }
    }
}

/// Whether the app may post notifications.
public enum NotificationAuthorization: Sendable, Equatable {
    /// Not asked yet.
    case notDetermined
    /// Allowed, fully or provisionally.
    case allowed
    /// Refused: only the Settings app can change it.
    case denied
}

/// Where the app asks for notifications: UserNotifications in the app, a stand-in in tests.
public protocol NotificationPermission: Sendable {
    /// The current answer.
    func authorization() async -> NotificationAuthorization
    /// Asks, when not asked yet, and answers the result.
    func request() async -> NotificationAuthorization
}
