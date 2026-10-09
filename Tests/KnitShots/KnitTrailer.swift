import XCTest

/// The store's video (ADR 2026-10.g3k9): opens the Nearby room on `-demoScene trailer` while `scripts/check.sh trailer`
/// films the Simulator, and waits there while the app's `DemoDirector` plays the film. The director plays the user too,
/// typing into the composer a key at a time, so no keyboard rises over the room as it would for a test that typed.
///
/// It keeps when it opens the room, when Sam answers, when Dani's photo lands and when the film ends, on the host's
/// clock, as an attachment named `trailer_marks`: the gate turns them into seconds into its recording, so
/// `build-trailer.sh` cuts the film and times its captions without anyone measuring it by eye. The film starts where the
/// room settles after `room`.
@MainActor
final class KnitTrailer: XCTestCase {
    /// What the script's posts say, which this test waits for: Sam's answer, Dani's photo, and Priya's, the last.
    private static let sam = "Trail's clear up top"
    private static let dani = "Saved you a spot by the fire"
    private static let priya = "Sunset from the summit"
    /// How long the last post and its reaction are left on screen before the film ends.
    private static let ending: TimeInterval = 2.5
    /// How long the whole film gets: about 40 s of beats, at a person's pace.
    private static let film: TimeInterval = 90

    func testTrailer() throws {
        var marks: [String] = []
        func mark(_ name: String) {
            marks.append("\(name)=\(Date().timeIntervalSince1970)")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemo", "-demoScene", "trailer"]
        app.launch()
        let room = try app.appear(AccessibilityID.chatRow("nearby"))
        mark("room")
        room.tap()
        try app.appear(AccessibilityID.chatThread)

        try post(saying: Self.sam, in: app).appear("Sam's answer", timeout: Self.film)
        mark("answer")
        try post(saying: Self.dani, in: app).appear("Dani's post", timeout: Self.film)
        mark("photo")
        try post(saying: Self.priya, in: app).appear("Priya's post", timeout: Self.film)
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "the last reaction")], timeout: Self.ending)
        mark("end")

        let attachment = XCTAttachment(string: marks.joined(separator: "\n"))
        attachment.name = "trailer_marks"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    /// The room's post whose words begin `words`.
    private func post(saying words: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", words)).firstMatch
    }
}
