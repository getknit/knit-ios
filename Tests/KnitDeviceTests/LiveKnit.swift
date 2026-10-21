import XCTest

/// Knit on the iPhone, launched live: the real radio, the Keychain identity and the SQL stores, never `-seedDemo`.
/// The tests read what Knit is doing from identifiers that name a state (``AccessibilityID/StatusState``), never from
/// its words, so the copy can change under them.
@MainActor
struct LiveKnit {
    typealias State = AccessibilityID.StatusState

    /// A mesh that runs with Bluetooth on, whether or not a lab phone is in range to link.
    static let running: Set<State> = [.linked, .looking]

    /// How long a state gets to show: a relaunch, a link coming back, or the radio answering a switch.
    static let settles: TimeInterval = 30

    let app = XCUIApplication()

    /// The terms' version (`Terms.version`, ADR 2026-10.cgm3), which every launch says the user agreed to, so the lab
    /// iPhone opens on the app rather than the terms. `TermsTests` holds the two equal. Onboarding still shows the terms.
    static let acceptedTerms = "2"

    /// Launches Knit afresh with `arguments`, and the terms agreed to, ending a process that was running. UserDefaults
    /// reads the argument domain first, so the agreement lasts this launch alone.
    func launch(_ arguments: String...) {
        app.launchArguments = ["-acceptedTerms", Self.acceptedTerms] + arguments
        app.launch()
    }

    /// The state the chat list's status line names, once it names one of `states`.
    @discardableResult
    func status(in states: Set<State>, timeout: TimeInterval = Self.settles) throws -> State {
        let ids = states.map(AccessibilityID.chatListStatus)
        let line = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", ids)).firstMatch
        try line.appear("the status line as one of \(states.map(\.rawValue).sorted())", timeout: timeout)
        let shown = line.identifier
        guard let state = states.first(where: { AccessibilityID.chatListStatus($0) == shown }) else {
            throw Mismatch(what: "the status line", expected: "\(states)", found: shown)
        }
        return state
    }

    /// Throws unless Knit's process is alive, in front or behind it: switching the radio must not end it.
    func stillRunning() throws {
        guard app.state != .notRunning else {
            throw Mismatch(what: "Knit's process", expected: "still running", found: "ended")
        }
    }

    /// Knit's Settings, from the chat list.
    func openSettings() throws {
        try app.appear(AccessibilityID.chatListSettings).tap()
        try app.appear(AccessibilityID.settingsScreen)
    }

    /// Stops a running mesh or starts a stopped one from Settings, and comes back to the chat list.
    func toggleMeshInSettings() throws {
        try openSettings()
        try app.reveal(AccessibilityID.settingsMesh).tap()
        app.back()
    }

    /// The node id the own profile shows, read from Settings; the chat list is on screen again after.
    func nodeId() throws -> String {
        try ownProfile { try app.appear(AccessibilityID.profileNodeId).label }
    }

    /// The name the own profile holds, or "" when the field shows only its prompt, the alias.
    func profileName() throws -> String {
        try ownProfile {
            let field = app.textFields.matching(identifier: AccessibilityID.profileName).firstMatch
            try field.appear(AccessibilityID.profileName)
            let value = field.value as? String ?? ""
            return value == field.placeholderValue ? "" : value
        }
    }

    private func ownProfile<Value>(_ read: () throws -> Value) throws -> Value {
        try openSettings()
        try app.reveal(AccessibilityID.settingsProfileRow).tap()
        try app.appear(AccessibilityID.profileScreen)
        let value = try read()
        app.back()
        app.back()
        return value
    }
}

/// Something on screen that was not what the test expected.
struct Mismatch: Error, CustomStringConvertible {
    let what: String
    let expected: String
    let found: String

    var description: String { "\(what): expected \(expected), found \(found)" }
}
