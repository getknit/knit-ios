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

    /// Photos in a thread, on the marketing scene, whose post by the fire carries one: the room with its photos, Add
    /// photo, which picks a painted picture under `-demoPhoto`, the photo the composer holds, the post that sends it, and
    /// that photo full screen with its Save. The picked picture stands upright, so our photo grows the most it can once it
    /// decodes, and the walk checks that the thread kept its stamp in view. The walk opens our own photo, the newest
    /// message: at the largest sizes a post further up scrolls in and out of the list's reach as the walk swipes. Save
    /// itself stays untapped, since the system would ask to add to Photos.
    func walkChatPhotos() throws {
        let app = launch("-demoScene", "marketing", "-demoPhoto")
        try app.reveal(AccessibilityID.chatRow("nearby")).tap()
        try app.appear(AccessibilityID.chatThread)
        audit(app, screen: AccessibilityID.chatThread)

        try app.appear(AccessibilityID.chatAddPhoto).tap()
        try app.appear(AccessibilityID.chatStagedPhoto)
        try app.appear(AccessibilityID.chatRemovePhoto)
        audit(app, screen: AccessibilityID.chatThread)
        try app.appear(AccessibilityID.chatSend).tap()
        XCTAssert(app.element(AccessibilityID.chatStagedPhoto).waitForNonExistence(timeout: Walking.appears), "Send kept the photo")
        try app.appear(AccessibilityID.chatAddPhoto)

        let fire = AccessibilityID.chatPhoto("room-5")
        let ours = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@", "chat_photo_", fire)).firstMatch
        try ours.appear("our photo")
        // The photo reads as such once it has decoded; until then its place holds a spinner, which a tap does nothing to.
        wait(for: ours, until: "label CONTAINS 'Photo'")
        // The decoded photo stands a hundred points taller than the spinner did, and the thread follows it down: its stamp
        // and tick end above the composer, where they used to end under it.
        let composer = try app.appear(AccessibilityID.chatInput)
        XCTAssertLessThanOrEqual(ours.frame.maxY, composer.frame.minY, "our photo's stamp sat under the composer")
        // A message reads as one element, so the tap goes where its photo is: above its stamp.
        ours.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        settle(try app.appear(AccessibilityID.photoViewerScreen))
        audit(app, screen: AccessibilityID.photoViewerScreen)
        wait(for: try app.appear(AccessibilityID.photoViewerSave), until: "isEnabled == true")
        app.buttons["Done"].tap()
        XCTAssert(app.element(AccessibilityID.photoViewerScreen).waitForNonExistence(timeout: Walking.appears), "Done left the photo up")
        app.terminate()
    }

    /// Waits for `element` to match `predicate`, and fails the walk if it never does.
    private func wait(for element: XCUIElement, until predicate: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: Walking.appears), .completed, "\(element) never matched \(predicate)")
    }
}

// swiftlint:enable prefer_nimble
