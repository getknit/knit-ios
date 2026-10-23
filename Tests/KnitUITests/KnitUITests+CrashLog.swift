// XCUITest has no Swift Testing form, and Nimble is no dependency of ours: XCTest's own assertions are the only ones.
// swiftlint:disable prefer_nimble

import XCTest

// MARK: Saved crash and hang reports

// Apart from the rest only to keep the class under SwiftLint's body and file lengths. `walkSettings` audits a saved crash
// at every size; this walk deletes them (ADR 2026-10.qhsv).
extension KnitUITests {
    /// What a report's screen says once nothing is saved.
    private static let noReports = "No crash or hang reports are saved on this iPhone."

    /// `-demoCrash`'s hang: Copy, then Delete all, which asks first and leaves the screen empty and Diagnostics with no
    /// row for either kind.
    func testDeleteAllEmptiesTheSavedReports() throws {
        let app = launch("-demoCrash")
        try app.appear(AccessibilityID.chatListSettings).tap()
        try app.reveal(AccessibilityID.settingsDiagnostics).tap()
        try app.reveal(AccessibilityID.diagnosticsLastCrash)
        try app.reveal(AccessibilityID.diagnosticsLastHang).tap()
        try app.appear(AccessibilityID.crashLogScreen)
        try app.reveal(AccessibilityID.crashLogCopy).tap()
        try app.buttons["Copied"].appear("Copy, once it copied")
        try app.reveal(AccessibilityID.crashLogDelete).tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "Delete all", "")).firstMatch
        settle(try confirm.appear("Delete all's question"))
        audit(app, screen: "Delete all's question")
        confirm.tap()
        try app.staticTexts[Self.noReports].appear("the empty report screen")
        app.back()
        try app.appear(AccessibilityID.diagnosticsScreen)
        // Diagnostics reads the store again as it comes back.
        XCTAssert(app.element(AccessibilityID.diagnosticsLastCrash).waitForNonExistence(timeout: Walking.appears), "a deleted crash")
        XCTAssert(app.element(AccessibilityID.diagnosticsLastHang).waitForNonExistence(timeout: Walking.appears), "a deleted hang")
        app.terminate()
    }
}
// swiftlint:enable prefer_nimble
