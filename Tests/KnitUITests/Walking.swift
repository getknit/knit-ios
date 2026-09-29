import XCTest

// Waiting for screens and controls, shared by the Simulator's walks (`KnitUITests`) and the iPhone's device tests
// (`KnitDeviceTests`), which XcodeGen compiles this file into by path. A screen that never appears throws `Missing`,
// which ends the test with what was missing.

/// A screen or control that never appeared, which ends the test.
struct Missing: Error, CustomStringConvertible {
    let what: String

    var description: String { "\(what) never appeared" }
}

/// How long things get.
enum Walking {
    /// How long a screen gets to appear. A cold Simulator takes seconds for the first launch.
    static let appears: TimeInterval = 20
    /// How many swipes a control lower down a screen gets to come into view.
    static let swipes = 8
}

@MainActor
extension XCUIApplication {
    /// The first element anywhere on screen with `identifier`.
    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any)[identifier].firstMatch
    }

    /// The element with `identifier`, once it appears.
    @discardableResult
    func appear(_ identifier: String) throws -> XCUIElement {
        try element(identifier).appear(identifier)
    }

    /// A control that may sit below the fold, as most do at the largest sizes: swiped into view before it is tapped.
    @discardableResult
    func reveal(_ identifier: String) throws -> XCUIElement {
        try reveal(element(identifier), identifier)
    }

    /// `element`, swiped into view.
    @discardableResult
    func reveal(_ element: XCUIElement, _ what: String) throws -> XCUIElement {
        try windows.firstMatch.appear("the window")
        // Down the screen first, then back up it: the control may be either side of where the screen was left.
        for _ in 0..<Walking.swipes where !(element.exists && element.isHittable) {
            swipeUp()
        }
        for _ in 0..<Walking.swipes where !(element.exists && element.isHittable) {
            swipeDown()
        }
        return try element.appear(what)
    }

    /// Back one screen, through the navigation bar.
    func back() {
        navigationBars.buttons.element(boundBy: 0).tap()
    }
}

@MainActor
extension XCUIElement {
    /// This element once it exists, or ``Missing`` naming `what` after `timeout`.
    @discardableResult
    func appear(_ what: String, timeout: TimeInterval = Walking.appears) throws -> XCUIElement {
        guard waitForExistence(timeout: timeout) else {
            throw Missing(what: what)
        }
        return self
    }
}
