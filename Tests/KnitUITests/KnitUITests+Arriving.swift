import XCTest

// MARK: Photos on their way

// A photo streaming in, apart from the rest only to keep the class under SwiftLint's body and file lengths.
extension KnitUITests {
    /// The photo-arriving scene's room: Sam's photo rings against the size its header declared and says how much of how
    /// much is in, and Priya's, from a sender that declared none, says how much is in (ADR 2026-10.y9qh). A message reads as
    /// one element, so each caption is read in its bubble's label. The thread is audited with both on screen.
    func testAPhotoOnItsWayShowsHowFarItHasGot() throws {
        let app = launch("-demoScene", "photo-arriving")
        try app.reveal(AccessibilityID.chatRow("nearby")).tap()
        try app.appear(AccessibilityID.chatThread)
        // The thread samples as it opens, so the captions replace the waiting line within a sample.
        wait(for: try app.reveal(AccessibilityID.chatPhoto("arriving-2")), until: "label CONTAINS ' of '")
        wait(for: try app.reveal(AccessibilityID.chatPhoto("arriving-3")), until: "label CONTAINS ' received'")
        audit(app, screen: AccessibilityID.chatThread)
        app.terminate()
    }
}
