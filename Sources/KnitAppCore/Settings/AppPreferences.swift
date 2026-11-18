public import Foundation
import KnitSync

/// The app's own settings, which outlive a launch: UserDefaults in the app, memory in tests and `-seedDemo`.
public protocol AppPreferences: AnyObject, Sendable {
    /// Whether onboarding finished on this install.
    var hasOnboarded: Bool { get set }
    /// Whether someone else's explicit photos and faces hide: Content filtering, on until it is turned off.
    var filtersContent: Bool { get set }
    /// The version of ``Terms`` the user agreed to on this install, or 0 before they agreed to any (ADR 2026-10.cgm3).
    var acceptedTerms: Int { get set }
    /// Whether the composer fetches a card for a link it holds: off until it is turned on (ADR 2026-11.hcvg). Only a
    /// build with link previews offers it.
    var linkPreviews: Bool { get set }
    /// Internet relays' list and switch as the bytes kept, `nil` until the list is first written (ADR 2026-11.adrq, P6):
    /// handles, flags and the consent nonce's copy, never an address. Only a debug build reads or keeps them.
    var relayBookData: Data? { get set }
}

extension AppPreferences {
    /// The relay list the kept bytes hold: none yet, a list, or bytes that do not read as one, which are left as they are.
    public var relayBook: StoredRelayBook {
        RelayBook.read(relayBookData)
    }
}

/// ``AppPreferences`` in memory.
public final class MemoryPreferences: AppPreferences {
    private let onboarded: Lock<Bool>
    private let filters: Lock<Bool>
    private let terms: Lock<Int>
    private let previews: Lock<Bool>
    private let relays = Lock<Data?>(nil)

    /// Preferences starting from `hasOnboarded`, `filtersContent`, `acceptedTerms` and `linkPreviews`.
    public init(hasOnboarded: Bool = false, filtersContent: Bool = true, acceptedTerms: Int = 0, linkPreviews: Bool = false) {
        onboarded = Lock(hasOnboarded)
        filters = Lock(filtersContent)
        terms = Lock(acceptedTerms)
        previews = Lock(linkPreviews)
    }

    public var hasOnboarded: Bool {
        get { onboarded.withLock { $0 } }
        set { onboarded.withLock { $0 = newValue } }
    }

    public var filtersContent: Bool {
        get { filters.withLock { $0 } }
        set { filters.withLock { $0 = newValue } }
    }

    public var acceptedTerms: Int {
        get { terms.withLock { $0 } }
        set { terms.withLock { $0 = newValue } }
    }

    public var linkPreviews: Bool {
        get { previews.withLock { $0 } }
        set { previews.withLock { $0 = newValue } }
    }

    public var relayBookData: Data? {
        get { relays.withLock { $0 } }
        set { relays.withLock { $0 = newValue } }
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
