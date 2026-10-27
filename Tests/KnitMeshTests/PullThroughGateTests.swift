import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// A pull-through's deadline (`PullThroughGateTest` in knit-next, ADR 2026-10.2drc): a custody window from the latest row,
/// when every row is a DM's.
@Suite struct PullThroughGateTests {
    private let day = PullThroughGate.windowMilliseconds

    private func row(_ id: String, sentAt: Int64, dm: Bool, from sender: Int = 2) -> AttachmentRow {
        AttachmentRow(id: id, senderId: TestPeer(seed: sender).nodeId, sentAt: sentAt, isDM: dm, conversationId: "")
    }

    @Test func aDmsAttachmentIsPulledThroughForACustodyWindowFromItsLatestRow() {
        #expect(day == 86_400_000, "custody's day (`ForwardRepository.DEFAULT_TTL_MS`), never a setting")
        #expect(PullThroughGate.until([row("a", sentAt: 1000, dm: true)]) == 1000 + day)
        let ours = row("b", sentAt: 5000, dm: true, from: 1)
        #expect(PullThroughGate.until([row("a", sentAt: 1000, dm: true), ours]) == 5000 + day, "ours count too, and the latest wins")
    }

    @Test func aGroupOrARoomRowNamingTheHashMeansNoDeadline() {
        #expect(PullThroughGate.until([row("a", sentAt: 0, dm: false)]) == nil, "a group's or a room's row")
        #expect(
            PullThroughGate.until([row("a", sentAt: 1000, dm: true), row("b", sentAt: 0, dm: false)]) == nil, "one among DMs is enough")
        #expect(PullThroughGate.until([]) == nil, "no row, nothing to judge")
    }

    @Test func aSentAtPastAnyClampSaturatesRatherThanTraps() {
        #expect(PullThroughGate.until([row("a", sentAt: .max - 1, dm: true)]) == .max)
    }
}
