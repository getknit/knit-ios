// XCUITest has no Swift Testing form, and Nimble is no dependency of ours: XCTest's own assertions are the only ones.
// swiftlint:disable prefer_nimble

import XCTest

// MARK: Photos

// The photo walk, apart from the rest only to keep the class under SwiftLint's body and file lengths.
extension KnitUITests {
    /// The marketing scene, whose people wear painted photos, with `-demoPhoto`, under which Choose photo picks a painted
    /// picture: the system's picker runs outside Knit, out of the walk's reach. The profile, the cropper, the profile
    /// again with the photo waiting for Save, and Sam's photo full screen.
    func walkPhotos() throws {
        let app = launch("-demoScene", "marketing", "-demoPhoto")
        try app.appear(AccessibilityID.chatListSettings).tap()
        try app.reveal(AccessibilityID.settingsProfileRow).tap()
        try app.appear(AccessibilityID.profileScreen)
        audit(app, screen: AccessibilityID.profileScreen)

        try app.reveal(AccessibilityID.profileChoosePhoto).tap()
        settle(try app.appear(AccessibilityID.photoCropScreen))
        audit(app, screen: AccessibilityID.photoCropScreen)
        try app.appear(AccessibilityID.photoCropChoose).tap()
        XCTAssert(app.element(AccessibilityID.photoCropScreen).waitForNonExistence(timeout: Walking.appears), "Choose left the cropper up")
        XCTAssert(try app.appear(AccessibilityID.profileSave).isEnabled, "a cropped photo waits for Save")
        try app.reveal(AccessibilityID.profileRemovePhoto)
        app.back()
        app.back()

        try openDirect(in: app)
        try app.appear(AccessibilityID.chatProfile).tap()
        try app.reveal(AccessibilityID.profileDetailsPhoto).tap()
        settle(try app.appear(AccessibilityID.photoViewerScreen))
        audit(app, screen: AccessibilityID.photoViewerScreen)
        app.buttons["Done"].tap()
        XCTAssert(app.element(AccessibilityID.photoViewerScreen).waitForNonExistence(timeout: Walking.appears), "Done left the photo up")
        app.terminate()
    }
}

// swiftlint:enable prefer_nimble
