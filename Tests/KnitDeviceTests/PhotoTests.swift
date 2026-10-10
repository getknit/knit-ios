// XCUITest has no Swift Testing form, and Nimble is no dependency of ours: XCTest's own assertions are the only ones.
// swiftlint:disable prefer_nimble

import XCTest

/// Our profile photo on the iPhone, live (ADR 2026-10.sepc): chosen, cropped and saved, so the lab's phones get it.
/// `-demoPhoto` hands Choose photo a demo photo, since the system's picker runs outside Knit. It keeps pictures of
/// the chat list's faces, the cropper, and the profile with the photo waiting for Save.
///
/// The photo stays set, for a look at the lab's phones afterwards: `interop.py bridge '{"cmd":"avatar","clear":true}'`
/// takes it away. Like ``CameraTests`` it needs no radio state of its own, so it leaves Bluetooth as it found it.
@MainActor
final class PhotoTests: XCTestCase {
    func testOurPhotoIsChosenCroppedAndSaved() throws {
        let knit = LiveKnit()
        let app = knit.app
        // A launch with no arguments afterwards, so the phone runs as interop.py expects.
        defer { knit.launch() }

        knit.launch("-demoPhoto")
        try knit.status(in: LiveKnit.running)
        keep(app, "the chat list")
        try knit.openSettings()
        try app.reveal(AccessibilityID.settingsProfileRow).tap()
        try app.appear(AccessibilityID.profileScreen)

        try app.reveal(AccessibilityID.profileChoosePhoto).tap()
        try app.appear(AccessibilityID.photoCropScreen)
        keep(app, "the cropper")
        try app.appear(AccessibilityID.photoCropChoose).tap()
        XCTAssert(app.element(AccessibilityID.photoCropScreen).waitForNonExistence(timeout: Walking.appears), "Choose left the cropper up")
        let save = try app.appear(AccessibilityID.profileSave)
        XCTAssert(save.isEnabled, "a cropped photo waits for Save")
        try app.reveal(AccessibilityID.profileRemovePhoto)
        keep(app, "the profile, its photo waiting for Save")

        save.tap()
        try app.appear(AccessibilityID.settingsScreen)
        keep(app, "Settings, wearing the photo")
    }

    /// Keeps a picture of the whole screen under `name`.
    private func keep(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

// swiftlint:enable prefer_nimble
