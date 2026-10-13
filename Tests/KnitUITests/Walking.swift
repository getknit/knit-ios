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
    /// How near the window's middle a revealed element's own middle is drawn, as a share of the window's height.
    static let middle: CGFloat = 0.25
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
        let found = try element.appear(what)
        center(found)
        return found
    }

    /// Drags `element`'s middle toward the window's when it is out of sight: at the largest sizes a message's row is
    /// taller than half the screen, a swipe can fling the thread past it, and a sliver on screen is hittable while a press
    /// on its middle lands off the screen. Slow, and held before it lets go, so the drag moves as far as it says.
    private func center(_ element: XCUIElement) {
        let window = windows.firstMatch
        let frame = window.frame
        guard !frame.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) else {
            return
        }
        for _ in 0..<Walking.swipes {
            let offset = element.frame.midY - frame.midY
            guard abs(offset) > frame.height * Walking.middle else {
                return
            }
            let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let by = min(abs(offset), frame.height / 3) * (offset > 0 ? -1 : 1)
            from.press(
                forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: by)), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
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
