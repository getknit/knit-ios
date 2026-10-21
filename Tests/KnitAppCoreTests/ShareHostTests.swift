import Foundation
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// The app's side of the share sheet: the chats it offers the sheet, the drain each move of the session runs, and the
/// notification a held share posts (ADR 2026-10.z7a8).
@MainActor
@Suite struct ShareHostTests {
    /// A host over a rig and an inbox of its own, onboarded unless told otherwise.
    private func host(_ rig: AppRig, _ scratch: ShareInboxTests.Scratch, onboarded: Bool = true) -> ShareHost {
        ShareHost(
            inbox: scratch.inbox,
            session: rig.session,
            codec: FakeCodec(),
            screening: nil,
            now: { 1_790_000_000_000 },
            onboarded: { onboarded },
            pause: { await Task.yield() }
        )
    }

    /// Yields until `done`, or gives up after a while.
    private func settle(until done: () -> Bool) async {
        for _ in 0..<1000 where !done() {
            await Task.yield()
        }
    }

    @Test func theSheetIsOfferedTheChatListsChats() async {
        let rig = AppRig()
        let scratch = ShareInboxTests.Scratch()
        await rig.pin(AppRig.sam, name: "Sam")
        await rig.receive("hi", from: AppRig.sam.nodeId, to: rig.me)
        await rig.session.accept(AppRig.sam.nodeId.string)
        await rig.receive("hello?", from: AppRig.stranger.nodeId, to: rig.me)
        host(rig, scratch).publishChats()
        let snapshot = ChatSnapshot.read(from: scratch.inbox)
        #expect(snapshot?.rows.map(\.id) == [Conversations.nearby, AppRig.sam.nodeId.string], "the room first, and no request")
        #expect(snapshot?.rows.map(\.kind) == [.room, .direct])
        #expect(snapshot?.rows.last?.title == "Sam" && snapshot?.rows.last?.initial == "S")
    }

    @Test func beforeOnboardingTheSheetIsOfferedNothing() {
        let rig = AppRig()
        let scratch = ShareInboxTests.Scratch()
        host(rig, scratch).publishChats()
        #expect(ChatSnapshot.read(from: scratch.inbox) != nil)
        host(rig, scratch, onboarded: false).publishChats()
        #expect(ChatSnapshot.read(from: scratch.inbox) == nil, "the last one is taken away")
    }

    /// A move of the session drains what waits, once for a burst of moves.
    @Test func aMoveOfTheSessionSendsWhatWaits() async throws {
        let rig = AppRig()
        let scratch = ShareInboxTests.Scratch()
        let shares = host(rig, scratch)
        try scratch.inbox.submit(.message("From the sheet", to: Conversations.nearby, hasPicture: false, at: 1), picture: nil, id: "A")
        shares.sessionMoved()
        shares.sessionMoved()
        await settle { !rig.mesh.calls.room.isEmpty }
        #expect(rig.mesh.calls.room == ["From the sheet"])
        #expect(ChatSnapshot.read(from: scratch.inbox) != nil, "and the chats are listed")
    }

    /// Moves before a pass starts cost that one pass. A move during its pause costs one more, once the pause is over,
    /// and then the host goes quiet until the next move.
    @Test func aBurstOfMovesRunsOnePassAndAMoveDuringItsPauseOneMore() async {
        let rig = AppRig()
        let scratch = ShareInboxTests.Scratch()
        let passes = Passes()
        let shares = ShareHost(
            inbox: scratch.inbox,
            session: rig.session,
            codec: FakeCodec(),
            screening: nil,
            now: { 1_790_000_000_000 },
            onboarded: { true },
            pause: { await passes.count() }
        )
        shares.sessionMoved()
        shares.sessionMoved()
        shares.sessionMoved()
        await settle { passes.counted == 1 }
        await quiet()
        #expect(passes.counted == 1, "three moves before the pass, one pass")

        passes.duringPause = { shares.sessionMoved() }
        shares.sessionMoved()
        await settle { passes.counted == 3 }
        await quiet()
        #expect(passes.counted == 3, "a move during the pause, one pass more, then quiet")
    }

    /// Yields long enough for a host with nothing queued to show it stays quiet.
    private func quiet() async {
        for _ in 0..<200 {
            await Task.yield()
        }
    }

    /// Counts the pauses a host takes, one per pass, and runs `duringPause` in the next one.
    @MainActor
    final class Passes {
        private(set) var counted = 0
        var duringPause: (() -> Void)?

        func count() {
            counted += 1
            let move = duringPause
            duringPause = nil
            move?()
        }
    }

    /// Started, the host drains at each move of the session after the first, without being told.
    @Test func aStartedHostFollowsTheSession() async throws {
        let rig = AppRig()
        let scratch = ShareInboxTests.Scratch()
        let shares = host(rig, scratch)
        shares.start()
        await settle { ChatSnapshot.read(from: scratch.inbox) != nil }
        try scratch.inbox.submit(.message("Later", to: Conversations.nearby, hasPicture: false, at: 2), picture: nil, id: "B")
        await rig.receive("a post", from: AppRig.sam.nodeId)
        await settle { !rig.mesh.calls.room.isEmpty }
        #expect(rig.mesh.calls.room == ["Later"])
    }

    @Test func aHeldSharePostsANotificationThatOpensItsChat() async throws {
        let rig = AppRig()
        let scratch = ShareInboxTests.Scratch()
        await rig.pin(AppRig.sam, name: "Sam")
        await rig.receive("hi", from: AppRig.sam.nodeId, to: rig.me)
        await rig.session.accept(AppRig.sam.nodeId.string)
        await rig.session.block(AppRig.sam.nodeId)
        let shares = host(rig, scratch)
        try scratch.inbox.submit(.message("Still there?", to: AppRig.sam.nodeId.string, hasPicture: false, at: 1), picture: nil, id: "C")
        _ = await shares.drain(atFront: false)
        await settle { rig.notifier.posted.contains { $0.id == ShareHost.heldId(AppRig.sam.nodeId.string) } }
        let posted = try #require(rig.notifier.posted.first { $0.id == ShareHost.heldId(AppRig.sam.nodeId.string) })
        #expect(posted.threadId == AppRig.sam.nodeId.string && posted.conversationId == AppRig.sam.nodeId.string)
        #expect(posted.title == "Sam" && posted.body == Copy.Share.held(.closed))
        #expect(shares.takeHeld(for: AppRig.sam.nodeId.string)?.manifest.text == "Still there?")
    }

    /// The UI tests leave words for the room through `-demoShare`, since the system's share sheet is out of their reach.
    @Test func theDemoCanLeaveWordsForTheRoom() {
        #expect(LaunchOptions(arguments: ["Knit", "-seedDemo", "-demoShare", "From the sheet"]).demoShare == "From the sheet")
        #expect(LaunchOptions(arguments: ["Knit", "-seedDemo", "-demoShare"]).demoShare == nil, "no words, no share")
        #expect(ShareInbox.wakeName(group: "group.app.getknit.knit.dev") == "group.app.getknit.knit.dev.share-left")
    }
}
