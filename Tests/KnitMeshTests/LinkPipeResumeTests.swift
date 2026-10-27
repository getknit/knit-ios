import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A photo cut off by a dying link resumes from the bytes its asker kept, played on both sides: engines and link managers
/// joined by ``LinkPipe``s, the cuts real teardowns (knit-next ADR 2026-10.wtyc, knit-ios #2). Ports the intent of
/// `AttachmentResumeLabTest`, sized to blobs-reviewer's three scenarios of the design pass: two holders and two cuts, a
/// bad prefix, and a relink inside the serve memo. The oracles are the pipes: the headers and asks that crossed, and the
/// FILE_CHUNK bytes carried.
@Suite struct LinkPipeResumeTests {
    private static let pictureBytes = 1_000_000
    /// The most one cut may cost on the air: a record, which the asker keeps anyway.
    private static let recordBytes = 16_384

    private let picture: [UInt8] = (0..<Self.pictureBytes).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 13) }
    private var hash: BlobHash { BlobHash(of: picture) }

    /// A DM from `sender` to `node` naming the picture, so `node` wants it from its next link-up.
    private func wants(_ node: PipeNode, from sender: PipeNode) {
        node.stores.conversations.accept(sender.nodeId.string)
        node.stores.messages.save(
            MessageRecord(
                id: frameIdOf("dm-picture"),
                senderId: sender.nodeId,
                recipientId: node.nodeId,
                conversationId: sender.nodeId.string,
                body: "",
                sentAt: EngineFixture.start,
                attachment: MessageAttachment(hash: hash)
            ))
    }

    /// What crossed as (holder, offset), in order.
    private func served(_ lab: PipeLab) -> [String] {
        lab.serves(of: hash).map { "\($0.from) \($0.offset.map(String.init) ?? "whole")" }
    }

    /// Each pipe carried at most one copy of the picture: one per (blob, link).
    private func oneCopyPerLink(_ lab: PipeLab, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(lab.pipes.allSatisfy { $0.serves.count { $0.hash == hash } <= 1 }, sourceLocation: sourceLocation)
    }

    @Test func aPictureCutTwiceIsFinishedByTwoHoldersWithoutResendingAByte() {
        let lab = PipeLab()
        let alice = lab.node(1)
        let bob = lab.node(2)
        let carol = lab.node(3)
        bob.hold(picture)
        carol.hold(picture)
        wants(alice, from: bob)

        // Bob's link drops 400 000 bytes in: the cut keeps what came.
        let toBob = lab.link(alice, bob, cutAfter: 400_000)
        #expect(lab.run { !toBob.isUp })
        let first = alice.partials.length(hash)
        #expect(first >= 400_000 && first < 400_000 + Self.recordBytes)

        // Carol comes into range: the link-up's ask names what was kept, and her link drops at 800 000.
        let toCarol = lab.link(alice, carol, cutAfter: 800_000 - first)
        #expect(lab.run { !toCarol.isUp })
        let second = alice.partials.length(hash)
        #expect(second >= 800_000 && second < 800_000 + Self.recordBytes, "the second cut got further, onto the first")

        // Bob is back once his serve memo has lapsed: he streams only the last fifth, and it lands whole.
        lab.clock.advance(BlobExchange.serveMemoMilliseconds)
        lab.link(alice, bob)
        #expect(lab.run { alice.stores.blobs.contains(hash) })
        #expect(alice.stores.blobs.bytes(of: hash) == picture)
        #expect(alice.partials.length(hash) == 0, "landed: nothing left to resume")
        #expect(served(lab) == ["\(bob.nodeId) whole", "\(carol.nodeId) \(first)", "\(bob.nodeId) \(second)"])
        #expect(lab.asks(for: hash).map(\.offset) == [nil, Int64(first), Int64(second)], "each ask named what was kept")
        oneCopyPerLink(lab)
        #expect(lab.chunkBytes <= picture.count + 2 * Self.recordBytes, "not a byte sent twice past a record a cut")
        #expect(alice.links.filesResumedIn == 2)
        // Counted once a resumed file's END is out (`onFileResumedOut`): Carol's tail was cut short of it.
        #expect(carol.links.filesResumedOut == 0 && bob.links.filesResumedOut == 1)
        #expect(alice.engine.blobCounts.splicesRefused == 0)
    }

    @Test func aBadPrefixsSpliceIsRefusedAndTheOtherHolderSendsTheWholeFileInsideOneCycle() {
        let lab = PipeLab()
        let alice = lab.node(1)
        let bob = lab.node(2)
        let carol = lab.node(3)
        bob.hold(picture)
        carol.hold(picture)
        wants(alice, from: bob)
        // What a cut left from a holder whose bytes were wrong.
        alice.partials.keep(hash, bytes: [UInt8](repeating: 0, count: 400_000), basedOn: nil, now: lab.clock.monotonicMilliseconds())

        lab.link(alice, bob)
        lab.link(alice, carol)
        #expect(lab.run { alice.engine.blobCounts.splicesRefused == 1 })
        let refusedAt = lab.clock.monotonicMilliseconds()
        #expect(alice.partials.length(hash) == 0, "the prefix may be what was wrong")
        #expect(lab.run { alice.stores.blobs.contains(hash) })
        #expect(alice.stores.blobs.bytes(of: hash) == picture)
        let serves = lab.serves(of: hash)
        #expect(serves.count == 2 && serves.first?.offset == 400_000 && serves.last?.offset == nil)
        let failing = serves.first?.from
        #expect(serves.last?.from != failing, "the other holder")
        #expect(serves.last.map { $0.at - refusedAt < BlobExchange.cycleMilliseconds } == true, "inside one cycle")
        let asksOfFailing = lab.asks(for: hash).filter { $0.to == failing }
        #expect(asksOfFailing.map(\.offset) == [400_000], "never asked again before the next natural cycle")
        oneCopyPerLink(lab)
        #expect(lab.chunkBytes <= picture.count - 400_000 + picture.count, "a tail lost, and one whole file")
        #expect(alice.links.filesResumedIn == 1)
    }

    @Test func aRelinkInsideTheServeMemoResumesAtItsFloorWithNoSecondCopyBeforeIt() {
        let lab = PipeLab()
        let alice = lab.node(1)
        let bob = lab.node(2)
        bob.hold(picture)
        wants(alice, from: bob)

        let first = lab.link(alice, bob, cutAfter: 100_000)
        #expect(lab.run { !first.isUp })
        let servedAt = first.serves.first?.at ?? 0
        #expect(lab.clock.monotonicMilliseconds() - servedAt < BlobExchange.serveMemoMilliseconds, "cut inside the memo")
        let kept = alice.partials.length(hash)

        lab.link(alice, bob)
        #expect(lab.run { alice.stores.blobs.contains(hash) })
        #expect(alice.stores.blobs.bytes(of: hash) == picture)
        #expect(served(lab) == ["\(bob.nodeId) whole", "\(bob.nodeId) \(kept)"])
        let resumedAt = lab.serves(of: hash).last?.at ?? 0
        #expect(resumedAt - servedAt >= BlobExchange.serveMemoMilliseconds, "the memo held the relink's ask to its floor")
        oneCopyPerLink(lab)
        #expect(lab.chunkBytes <= picture.count + Self.recordBytes)
        #expect(alice.links.filesResumedIn == 1 && bob.links.filesResumedOut == 1)
    }
}
