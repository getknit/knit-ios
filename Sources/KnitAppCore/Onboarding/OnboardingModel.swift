import KnitMesh
import KnitStore
import KnitWire
public import Observation

/// Where onboarding stands (MVP item 1): welcome, then an optional name, then the permissions.
public enum OnboardingStep: Int, Sendable, CaseIterable {
    /// What Knit is.
    case welcome = 0
    /// The name people nearby see; blank keeps the alias.
    case name = 1
    /// Bluetooth, and optionally notifications.
    case permissions = 2
}

/// Where the Bluetooth permission stands, as the permissions page shows it.
public enum BluetoothGrant: Sendable, Equatable {
    /// Not asked yet: the radio has not started.
    case notAsked
    /// Asked, and the system has not answered.
    case asking
    /// Allowed; the radio may still be switched off.
    case allowed
    /// Refused: only the Settings app can change it.
    case denied
    /// No Bluetooth LE here.
    case unsupported
}

/// Onboarding's view model. Finishing publishes the profile even with no name, so its version moves to now: a
/// reinstall that finds its old identity in the Keychain takes its presentation back from peers holding an older one
/// (ADR 2026-09.tkww).
@preconcurrency
@MainActor
@Observable
public final class OnboardingModel {
    /// The page on screen.
    public private(set) var step = OnboardingStep.welcome
    /// Whether onboarding is done.
    public private(set) var isFinished: Bool
    /// Whether the app may notify.
    public private(set) var notifications = NotificationAuthorization.notDetermined
    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private let preferences: any AppPreferences
    @ObservationIgnored private let permission: (any NotificationPermission)?
    private var nameText = ""

    /// Onboarding over `session`, remembering that it finished in `preferences`.
    public init(session: AppSession, preferences: any AppPreferences, permission: (any NotificationPermission)?) {
        self.session = session
        self.preferences = preferences
        self.permission = permission
        isFinished = preferences.hasOnboarded
    }

    /// The name as typed, cut at ``TextLimits/displayName`` UTF-16 units.
    public var name: String {
        get { nameText }
        set { nameText = TextLimits.truncated(newValue, toUTF16: TextLimits.displayName) }
    }

    /// The alias people see while the name is blank.
    public var alias: String {
        session.identity.alias
    }

    /// Whether the name page's button skips rather than continues.
    public var skipsName: Bool {
        TextLimits.isBlank(nameText)
    }

    /// "Step 1 of 2" over the name and permissions pages; the welcome page has none.
    public var progress: String? {
        step == .welcome ? nil : Copy.Onboarding.step(step.rawValue, of: OnboardingStep.allCases.count - 1)
    }

    /// Where Bluetooth stands.
    public var bluetooth: BluetoothGrant {
        switch session.radioState {
        case nil:
            session.isRunning ? .asking : .notAsked
        case .on, .off:
            .allowed
        case .unauthorized:
            .denied
        case .unsupported:
            .unsupported
        }
    }

    /// The next page.
    public func next() {
        step = OnboardingStep(rawValue: step.rawValue + 1) ?? .permissions
    }

    /// The page before.
    public func back() {
        step = OnboardingStep(rawValue: step.rawValue - 1) ?? .welcome
    }

    /// Starts the radio, which is what makes the system ask for Bluetooth.
    public func allowBluetooth() async {
        await session.start()
    }

    /// Asks for notifications.
    public func allowNotifications() async {
        notifications = await permission?.request() ?? .denied
    }

    /// Reads the notification permission again, as the app returns to the front.
    public func refresh() async {
        notifications = await permission?.authorization() ?? .denied
    }

    /// Publishes the profile, starts the mesh if it is not running, and remembers that onboarding is done.
    public func finish() async {
        let own = session.stores.ownProfile.load()
        await session.updateProfile(
            name: Composer.singleLine(nameText, limit: TextLimits.displayName),
            status: own.status,
            openToChat: own.openToChat
        )
        if !session.isRunning {
            await session.start()
        }
        preferences.hasOnboarded = true
        isFinished = true
    }
}
