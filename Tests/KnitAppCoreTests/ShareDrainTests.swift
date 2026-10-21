import Foundation
import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// The app's side of the share sheet: each share sent through the composer's own rules, each refusal held for its
/// thread's composer, and a contact link kept for the front (ADR 2026-10.z7a8).
@MainActor
@Suite struct ShareDrainTests {
    nonisolated private static let picked = Data("a picked photo".utf8)
    /// What ``FakeCodec`` prepares from ``picked``.
    nonisolated private static let prepared = Array("ready ".utf8) + Array(picked)

    /// A rig, an inbox of its own, and a drain over both that records the threads it held shares for.
    @MainActor
    final class Bench {
        let rig: AppRig
        let scratch = ShareInboxTests.Scratch()
        let drain: ShareDrain
        private let log: Log
        private var next = 0

        /// The threads the drain held shares for, in order.
        @MainActor
        final class Log {
            var threads: [String] = []
        }

        init(screening: TextScreening? = nil, codec: FakeCodec = FakeCodec(), photos: [[UInt8]: [Float]]? = nil) {
            let made = AppRig(screening: screening)
            rig = made
            let screener = photos.map { PhotoScreening(classifier: FakeClassifier($0), session: made.session) }
            let threads = Log()
            log = threads
            drain = ShareDrain(
                inbox: scratch.inbox,
                session: made.session,
                codec: codec,
                screening: screener,
                now: { 1_790_000_000_000 },
                held: { threads.threads.append($0) }
            )
        }

        var heldFor: [String] { log.threads }

        /// Leaves `text` for `conversationId` in the inbox, with ``ShareDrainTests/picked`` beside it when `picture`.
        func share(_ text: String, to conversationId: String, picture: Bool = false) throws {
            next += 1
            let file = picture ? try scratch.picture(ShareDrainTests.picked, named: "pick\(next)") : nil
            try scratch.inbox.submit(
                .message(text, to: conversationId, hasPicture: picture, at: Int64(next)), picture: file, id: "S\(next)")
        }

        var inboxIsEmpty: Bool { scratch.inbox.pending().isEmpty }
    }

    // MARK: Sending

    @Test func roomWordsGoToTheRoom() async throws {
        let bench = Bench()
        try bench.share("Anyone at the falls?", to: Conversations.nearby)
        let link = await bench.drain.drain(atFront: false)
        #expect(link == nil)
        #expect(bench.rig.mesh.calls.room == ["Anyone at the falls?"])
        #expect(bench.inboxIsEmpty && bench.heldFor.isEmpty)
    }

    @Test func aPictureGoesToADMAsTheComposerWouldSendIt() async throws {
        let bench = Bench()
        try bench.share("From the top", to: AppRig.sam.nodeId.string, picture: true)
        await bench.drain.drain(atFront: false)
        #expect(bench.rig.mesh.calls.direct == ["\(AppRig.sam.nodeId): From the top"])
        #expect(bench.rig.mesh.calls.photos == [BlobHash(of: Self.prepared)], "the codec made it ready")
        #expect(bench.inboxIsEmpty)
    }

    @Test func aShareGoesToAGroupWeHold() async throws {
        let bench = Bench()
        let group = try #require(await bench.rig.session.createGroup(with: [AppRig.sam.nodeId, AppRig.priya.nodeId]))
        try bench.share("Dinner at 7", to: group.id)
        await bench.drain.drain(atFront: false)
        #expect(bench.rig.mesh.calls.groups.last == "send \(group.id): Dinner at 7")
        #expect(bench.inboxIsEmpty && bench.heldFor.isEmpty)
    }

    /// The drain seeds the words rather than typing them, so a share sent in the background tells nobody we are typing.
    @Test func aDrainCuesNoTyping() async throws {
        let bench = Bench()
        try bench.share("No dots", to: AppRig.sam.nodeId.string)
        await bench.drain.drain(atFront: true)
        #expect(bench.rig.mesh.calls.direct.count == 1)
        #expect(bench.rig.mesh.calls.typing.isEmpty)
    }

    @Test func nothingToSendOrNoThreadIsDropped() async throws {
        let bench = Bench()
        try bench.share("   ", to: Conversations.nearby)
        try bench.share("To myself", to: AppRig.me.nodeId.string)
        try bench.share("To nowhere", to: "not a thread")
        await bench.drain.drain(atFront: false)
        #expect(bench.rig.mesh.calls == FakeMesh.Calls())
        #expect(bench.inboxIsEmpty && bench.heldFor.isEmpty)
    }

    // MARK: Refusals

    /// Each refusal holds the share for its thread and says so, and nothing reaches the mesh.
    @Test(arguments: [Refused.blocked, .leftGroup, .request, .slurInTheRoom, .explicitInTheRoom, .unreadable, .tooLarge])
    func aRefusedShareIsHeldForItsThread(_ refused: Refused) async throws {
        let bench = Bench(
            screening: TextScreening(classifier: nil, words: WordFilter(words: ["shit"]), slurs: WordFilter(words: [])),
            codec: refused == .unreadable ? FakeCodec(reads: false) : refused == .tooLarge ? FakeCodec(refuses: .tooLarge) : FakeCodec(),
            photos: [Self.prepared: FakeClassifier.explicit]
        )
        let thread = try await refused.thread(in: bench.rig)
        let before = bench.rig.mesh.calls
        try bench.share(refused == .slurInTheRoom ? "oh shit" : "hello", to: thread, picture: refused.hasPicture)
        await bench.drain.drain(atFront: false)
        #expect(bench.rig.mesh.calls.room == before.room && bench.rig.mesh.calls.direct == before.direct)
        #expect(bench.rig.mesh.calls.groups == before.groups)
        #expect(bench.heldFor == [thread])
        #expect(bench.inboxIsEmpty)
        let held = try #require(bench.scratch.inbox.held(in: thread).first)
        #expect(held.manifest.refusal == refused.refusal)
    }

    enum Refused: CaseIterable, Sendable {
        case blocked
        case leftGroup
        case request
        case slurInTheRoom
        case explicitInTheRoom
        case unreadable
        case tooLarge

        var hasPicture: Bool { [.explicitInTheRoom, .unreadable, .tooLarge].contains(self) }

        var refusal: ShareManifest.Refusal {
            switch self {
            case .blocked, .leftGroup, .request:
                .closed
            case .slurInTheRoom:
                .words
            case .explicitInTheRoom:
                .explicitPhoto
            case .unreadable:
                .unreadablePhoto
            case .tooLarge:
                .photoTooLarge
            }
        }

        /// The thread the share goes to, made as this case needs it.
        @MainActor
        func thread(in rig: AppRig) async throws -> String {
            switch self {
            case .blocked:
                await rig.receive("hi", from: AppRig.sam.nodeId, to: rig.me)
                await rig.session.accept(AppRig.sam.nodeId.string)
                await rig.session.block(AppRig.sam.nodeId)
                return AppRig.sam.nodeId.string
            case .leftGroup:
                let group = try #require(await rig.session.createGroup(with: [AppRig.sam.nodeId, AppRig.priya.nodeId]))
                _ = await rig.session.leaveGroup(group.id)
                return group.id
            case .request:
                await rig.receive("hello?", from: AppRig.stranger.nodeId, to: rig.me)
                return AppRig.stranger.nodeId.string
            case .slurInTheRoom, .explicitInTheRoom:
                return Conversations.nearby
            case .unreadable, .tooLarge:
                return AppRig.sam.nodeId.string
            }
        }
    }

    /// A held share comes back into its thread's composer, words and picture, with the alert the composer itself would
    /// have shown; then it is gone.
    @Test func aHeldShareReturnsToTheComposer() async throws {
        let bench = Bench(
            screening: TextScreening(classifier: nil, words: WordFilter(words: ["shit"]), slurs: WordFilter(words: [])),
            photos: [:]
        )
        try bench.share("oh shit, look", to: Conversations.nearby, picture: true)
        await bench.drain.drain(atFront: false)
        let held = bench.drain.takeHeld(for: Conversations.nearby)
        try #require(held.count == 1)
        #expect(bench.drain.takeHeld(for: Conversations.nearby).isEmpty, "taken once")

        let model = ChatModel(conversationId: Conversations.nearby, session: bench.rig.session, codec: FakeCodec())
        await model.adopt(held[0].manifest, picture: held[0].picture)
        #expect(model.draft == "oh shit, look" && model.wordsRefused)
        #expect(model.staged?.photo.bytes == Self.prepared)
        #expect(model.selection == 13..<13, "the caret at the end")
        #expect(bench.rig.mesh.calls.typing.isEmpty)
    }

    // MARK: Contact links

    /// A contact link waits for the front, where Add contact can open, then comes out once.
    @Test func aContactLinkWaitsForTheFront() async throws {
        let bench = Bench()
        let link = try #require(ContactCard.encode(AppRig.priya.keys, name: "Priya", issuedAt: 1_790_000_000_000)?.url)
        try bench.scratch.inbox.submit(.contactLink(link, at: 1), picture: nil, id: "L")
        #expect(await bench.drain.drain(atFront: false) == nil)
        #expect(bench.scratch.inbox.pendingCount() == 1, "still waiting")
        #expect(await bench.drain.drain(atFront: true) == link)
        #expect(bench.inboxIsEmpty)
        #expect(await bench.drain.drain(atFront: true) == nil)
    }
}
