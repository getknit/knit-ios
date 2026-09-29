import XCTest

/// MVP item 1 on the iPhone, live: Knit ended and launched again keeps its node, skips onboarding, and runs.
@MainActor
final class RelaunchTests: XCTestCase {
    func testRelaunchKeepsTheNode() throws {
        let phone = Phone()
        try phone.restore()
        defer { try? phone.restore() }
        let knit = phone.knit
        let before = try knit.nodeId()

        knit.app.terminate()
        knit.launch()
        try knit.status(in: LiveKnit.running)
        try knit.app.appear(AccessibilityID.chatRow("nearby"))
        let after = try knit.nodeId()
        guard after == before else {
            throw Mismatch(what: "the node id", expected: before, found: after)
        }
    }
}
