import XCTest

/// A contact link opened outside Knit, live (ADR 2026-10.tpr5): iOS itself opens `https://getknit.app/c#…`, as a tap in
/// Messages or Notes does, and hands it to Knit as a universal link, because getknit.app's apple-app-site-association
/// file claims `/c` for Knit and the build carries `applinks:getknit.app`. The phone reads that file from Apple's CDN
/// after Knit is installed, so the test gives it a minute, and names Safari when Safari took the link instead.
///
/// The card is knit-next's `minimalCard` (`ContactCardTest.kt`, also in `KnitUITests+AddContact.swift`), a person no lab
/// phone is. Knit launches again at the end, which closes the preview unconfirmed, so nothing is pinned.
@MainActor
final class LinkTests: XCTestCase {
    private static let minimalCard =
        "omRib2R5WGijYXYBYmlkeBo0Y2dxMnBuaGg2cDNqM2Fmd3N1ZTNjaHJwaWJwa1hA5AMJmM_VrRcj"
        + "wWn5VqoLnrhhm1mSvWEsKvQo68efjfBz55lxyREAKXI2MqgLcHv09iwSV2M0bh6HGNbA3MOqOmNz"
        + "aWdYQLL2FdNZ6dxdvl8HfEBnbj8yNsSoGoCPELMEIXuO6kA04Ra6SeNRPkpg1UGmp1ZQgU3qjVOp"
        + "M6JdH3puOvfihQA"

    /// How long the phone gets to read the association file after an install.
    private static let associates: TimeInterval = 60

    func testAGetknitLinkOpensAddContact() throws {
        let knit = LiveKnit()
        let app = knit.app
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        let link = try XCTUnwrap(URL(string: "https://getknit.app/c#" + Self.minimalCard))
        defer { knit.launch() }

        knit.launch()
        try app.appear(AccessibilityID.chatListNewMessage)
        let deadline = Date.now.addingTimeInterval(Self.associates)
        var opened = false
        repeat {
            XCUIDevice.shared.press(.home)
            XCUIDevice.shared.system.open(link)
            opened = app.wait(for: .runningForeground, timeout: Walking.appears)
        } while !opened && Date.now < deadline
        guard opened else {
            let found = safari.state == .runningForeground ? "Safari" : "neither Knit nor Safari"
            throw Mismatch(what: "the app that opened getknit.app/c", expected: "Knit", found: found)
        }
        try app.appear(AccessibilityID.addContactPreview)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Add contact's preview of the link"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
