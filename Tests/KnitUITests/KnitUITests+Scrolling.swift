// XCUITest has no Swift Testing form, and Nimble is no dependency of ours: XCTest's own assertions are the only ones.
// swiftlint:disable prefer_nimble

import XCTest

// MARK: Scrolling

// The scrolling walk, apart from the rest only to keep the class under SwiftLint's body and file lengths.
extension KnitUITests {
    /// A thread scrolled up offers the way back to its newest message, and a tap on the bar takes it to its top to stay.
    func testAThreadScrolledUpOffersTheWayBackToItsNewestMessage() throws {
        try walkScrolling()
    }

    /// A room far longer than the screen opens on its newest post, each time it is opened.
    func testALongRoomOpensOnItsNewestPost() throws {
        try walkLongRoom()
    }

    /// A room far longer than the screen, dragged up its history, moves with the finger and nothing else.
    func testALongRoomDraggedUpMovesWithTheFinger() throws {
        try walkLongRoomDrags()
    }

    /// A thread's photos and its scrolling, for the walks every screen takes again.
    func walkThreadPhotosAndScrolling() throws {
        try walkChatPhotos()
        try walkScrolling()
        try walkLongRoom()
        try walkLongRoomDrags()
    }

    /// The marketing scene's room, the longest thread the demo seeds. A tap on the navigation bar's empty end scrolls it to
    /// its first post and leaves it there, where it once snapped back down, and the way back to the newest post offers
    /// itself. The way back takes the room to its newest post and goes. Swiped up the room by hand, it offers itself
    /// again, and a post of our own takes the room down to it.
    func walkScrolling() throws {
        let app = launch("-demoScene", "marketing")
        try app.reveal(AccessibilityID.chatRow("nearby")).tap()
        let thread = try app.appear(AccessibilityID.chatThread)
        let newest = try app.appear(AccessibilityID.chatMessage("room-9"))
        let way = app.element(AccessibilityID.chatScrollToNewest)
        XCTAssertFalse(way.exists, "a thread that opens on its newest post offered the way back to it")

        // The room has no lock, so the bar's trailing end holds nothing for a tap to land on: iOS scrolls to the top.
        let bar = app.navigationBars.firstMatch.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: bar.maxX - bar.height, dy: bar.midY)).tap()
        let first = app.element(AccessibilityID.chatMessage("room-1"))
        wait(for: first, until: "isHittable == true")
        settle(first)
        XCTAssert(first.isHittable, "the room left its first post after the bar took it there")
        try way.appear("the way back to the newest post")
        audit(app, screen: AccessibilityID.chatThread)

        way.tap()
        XCTAssert(way.waitForNonExistence(timeout: Walking.appears), "the way back stayed at the newest post")
        wait(for: newest, until: "isHittable == true")

        for _ in 0..<Walking.swipes where !way.exists {
            thread.swipeDown()
        }
        try way.appear("the way back, after a swipe up the room")
        let input = try app.appear(AccessibilityID.chatInput)
        input.tap()
        input.typeText("Back at camp")
        try app.appear(AccessibilityID.chatSend).tap()
        XCTAssert(way.waitForNonExistence(timeout: Walking.appears), "our own post left the room up in its history")
        wait(for: try app.staticTexts["Back at camp"].appear("our post"), until: "isHittable == true")
        app.terminate()
    }
}

// MARK: Opening a long room

extension KnitUITests {
    /// How many times the long room is opened: the first open drew it right where a later one stopped short.
    private static let roomOpenings = 3

    /// The long-room scene's room, whose rows the lazy stack has mostly guessed the height of as it opens. Each time, it
    /// opens with its newest post above the composer. Reopened, it once stopped 150 points short, its newest posts under
    /// the composer, when the bars settling as it opened read as a tap on the bar scrolling it to the top.
    func walkLongRoom() throws {
        let app = launch("-demoScene", "long-room")
        for _ in 0..<Self.roomOpenings {
            try app.reveal(AccessibilityID.chatRow("nearby")).tap()
            let newest = try app.appear(AccessibilityID.chatMessage("long-239"))
            let composer = try app.appear(AccessibilityID.chatInput)
            settle(newest)
            XCTAssertLessThanOrEqual(newest.frame.maxY, composer.frame.minY, "the room opened short of its newest post")
            app.back()
        }
        app.terminate()
    }
}

// MARK: Dragging up a long room

extension KnitUITests {
    /// How many times the long room is dragged up, each about a third of the screen: far enough up its history for UIKit
    /// to measure a few dozen rows it had only estimated.
    private static let roomDrags = 12
    /// How fast the room is dragged, in points a second: slowly, so the finger is still down as rows come in above.
    private static let dragSpeed: CGFloat = 300
    /// How long the finger rests before it lifts, so the room does not glide on.
    private static let dragRest: TimeInterval = 0.2
    /// How far a post may end from where the finger took it: the pan's own slop before the thread follows.
    private static let dragSlop: CGFloat = 12

    /// The long-room scene's room, dragged up its history. Each time, a post on screen moves exactly as far as the finger
    /// does, whatever the rows that come in above it measure. The thread once corrected its offset for those rows
    /// on top of UIKit's own correction, and threw itself down by what each differed from UIKit's estimate (ADR
    /// 2026-10.pkbu).
    func walkLongRoomDrags() throws {
        let app = launch("-demoScene", "long-room")
        try app.reveal(AccessibilityID.chatRow("nearby")).tap()
        let thread = try app.appear(AccessibilityID.chatThread)
        settle(try app.appear(AccessibilityID.chatMessage("long-239")))
        // A post with a photo takes the photo's name.
        let named = NSPredicate(
            format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@",
            AccessibilityID.chatMessage("long-"),
            AccessibilityID.chatPhoto("long-"))
        let posts = app.descendants(matching: .any).matching(named)
        for _ in 0..<Self.roomDrags {
            let room = thread.frame
            let start = thread.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            let end = thread.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            let dragged = end.screenPoint.y - start.screenPoint.y
            // A post on screen whose top the drag leaves above the room's bottom edge, so its row stays laid out. At the
            // largest sizes one post with a photo can fill the room, its top above it.
            let onScreen = posts.allElementsBoundByIndex.first { post in
                post.frame.maxY > room.minY && post.frame.minY + dragged < room.maxY
            }
            guard let post = onScreen else {
                XCTFail("no post on screen to drag")
                return
            }
            let held = app.element(post.identifier)
            let top = held.frame.minY
            let speed = XCUIGestureVelocity(rawValue: Self.dragSpeed)
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: speed, thenHoldForDuration: Self.dragRest)
            settle(held)
            let moved = held.frame.minY - top
            XCTAssertEqual(moved, dragged, accuracy: Self.dragSlop, "\(post.identifier) strayed from the finger")
        }
        app.terminate()
    }
}

// swiftlint:enable prefer_nimble
