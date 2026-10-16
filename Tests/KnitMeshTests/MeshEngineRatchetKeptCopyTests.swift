import Foundation
import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// The copy a failed unit kept, against the other copies of its frame (ADR 2026-10.5sk9, phase P5a; the round-three
/// reviews): it goes once any copy of its id commits, so a ctl frame, which never has a row, is not opened a second time
/// past an era change; an unsigned copy never displaces the signed one kept; a kept receipt flips its tick once; and the
/// copy's hop ranks the photo's pull-through as a live delivery's would. Each runs over the memory stores and the
/// database, whose units a refused write fails (``StoreKind``).
@Suite struct MeshEngineRatchetKeptCopyTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    /// A carrier that hands a frame over again.
    private let carol = TestPeer(seed: 3)
    private static let minute: Int64 = 60_000
    private var now: Int64 { EngineFixture.start }
    private var sweep: Int64 { MeshConfiguration().sweepMilliseconds }

    /// The crypto re-review's first finding. Android, its clock 30 minutes fast, sends `older`, whose first copy's unit
    /// fails on a refused write; the store heals and a carrier's copy comes in through the reopen and commits, at the
    /// stamp `clampFuture` gives it then. `newer` applies two minutes later, we reset, and one sweep runs: a kept copy
    /// still there would open again past the era change, clamped later, and outrank `newer`. `held` reads the value.
    private func sweepAfterAnotherCopyCommitted(
        _ kind: StoreKind, _ older: MessageContent, _ newer: MessageContent, held: (MeshStores) -> String?
    ) throws {
        let directory = scratchDirectory("kept-ctl")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingOpens(blobs: directory, failures: ReportedFailures().record)
        let iphone = try EngineFixture.ratcheting(me, stores: stores)
        let android = try AndroidPeer(alice)
        try iphone.pin(android)
        let prekey = try iphone.ourPrekey()
        let fast = 30 * Self.minute

        let olderFrame = try android.dm(older, to: me, prekey: prekey, id: "older", sentAt: now + fast)
        refusing.refusesWrites = true
        iphone.deliver(olderFrame, from: android)
        refusing.refusesWrites = false
        #expect(iphone.engine.dropped[.storeRefused] == 1)
        iphone.deliver(olderFrame, from: carol)
        iphone.clock.advance(2 * Self.minute)
        iphone.deliver(try android.dm(newer, to: me, prekey: prekey, id: "newer", sentAt: now + fast + 2 * Self.minute), from: android)
        let shown = held(stores)

        guard case .sent = iphone.engine.sendRatchetReset(to: alice.nodeId) else {
            Issue.record("our reset goes")
            return
        }
        let duplicates = iphone.engine.dropped[.ratchetDuplicate, default: 0]
        iphone.advance(sweep)
        #expect(held(stores) == shown, "the newer value stands")
        #expect(iphone.engine.dropped[.ratchetDuplicate, default: 0] == duplicates, "nothing was opened again")
    }

    @Test(arguments: StoreKind.allCases)
    func aKeptReactionGoesOnceAnotherCopyOfItCommits(kind: StoreKind) throws {
        func reaction(_ emoji: String) -> MessageContent {
            MessageContent(body: "", ctl: MessageContent.Control.reaction, rp: ReactionContent(messageId: "m1", emoji: emoji))
        }
        try sweepAfterAnotherCopyCommitted(kind, reaction("👍"), reaction("❤️")) { stores in
            stores.messages.reaction(on: "m1", by: alice.nodeId)?.emoji
        }
    }

    @Test(arguments: StoreKind.allCases)
    func aKeptProfileGoesOnceAnotherCopyOfItCommits(kind: StoreKind) throws {
        func profile(_ name: String, at version: Int64) -> MessageContent {
            MessageContent(body: "", ctl: MessageContent.Control.profile, pr: ProfilePayload(name: name, status: "", version: version))
        }
        let older = profile("Ann", at: now + 30 * Self.minute)
        let newer = profile("Annie", at: now + 32 * Self.minute)
        try sweepAfterAnotherCopyCommitted(kind, older, newer) { stores in
            stores.peers.peer(alice.nodeId)?.name
        }
    }

    /// The crypto re-review's second finding: while writes are refused, a carrier hands over a signed v3 DM's frame with
    /// its signature stripped, point to point. It passes the router through the reopen the signed copy's failure granted,
    /// and the door by its shape, and its own unit fails before it could be refused as unsigned. Kept in place of the
    /// signed copy, it would be refused at the sweep and the DM lost; it never displaces it.
    @Test(arguments: StoreKind.allCases)
    func anUnsignedCopyNeverDisplacesTheSignedCopyKept(kind: StoreKind) throws {
        let directory = scratchDirectory("kept-unsigned")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingOpens(blobs: directory, failures: ReportedFailures().record)
        let iphone = try EngineFixture.ratcheting(me, stores: stores)
        let android = try AndroidPeer(alice)
        try iphone.pin(android)
        let frame = try android.dm("hello", to: me, prekey: try iphone.ourPrekey(), id: "dm-1", sentAt: now, v3: true)
        let stripped = TestFrame(wire: WireEnvelope(relay: false, sig: [], signed: frame.envelope.encoded), envelope: frame.envelope)

        refusing.refusesWrites = true
        iphone.deliver(frame, from: android)
        iphone.deliver(stripped, from: carol)
        refusing.refusesWrites = false
        #expect(iphone.engine.dropped[.storeRefused] == 2, "both copies' units failed")

        iphone.advance(sweep)
        #expect(stores.messages.message("dm-1")?.body == "hello")
        #expect(iphone.acknowledged(by: android) == ["dm-1"])
        #expect(iphone.engine.dropped[.unsigned] == nil)
    }

    /// The blobs re-review's owed test: the copy kept keeps the hop it came over, which ranks the photo's pull-through as
    /// a live delivery from that neighbour would, where a copy with no hop asks every neighbour that lacks it.
    @Test(arguments: StoreKind.allCases)
    func theCopyKeptAsksItsHopAloneToPullThePhotoThrough(kind: StoreKind) throws {
        let directory = scratchDirectory("kept-hop")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let configuration = MeshConfiguration(queriesBlobHolders: true, ratchet: true)
        let iphone = try EngineFixture.ratcheting(me, stores: stores, configuration: configuration)
        let android = try AndroidPeer(alice)
        try iphone.pin(android)
        let hop = TestPeer(seed: 4)
        let other = TestPeer(seed: 5)
        iphone.link(hop, other, capabilities: Capabilities.local.union(.blobHave))
        let sealed = try #require(AttachmentCrypto.seal(Array("a picture".utf8)))
        let hash = BlobHash(of: sealed.blob)
        let content = MessageContent(
            body: "look", attachmentHash: hash.string, attachmentMime: "image/jpeg", attachmentKey: Base64.encode(sealed.key))
        let frame = try android.dm(content, to: me, prekey: try iphone.ourPrekey(), id: "photo-1", sentAt: now)
        iphone.transport.clear()

        refusing.refusesRows = true
        iphone.deliver(frame, from: hop)
        refusing.refusesRows = false
        #expect(iphone.transport.written(.blobHave).isEmpty && iphone.transport.written(.blobRequest).isEmpty)

        iphone.advance(sweep)
        let queries = iphone.transport.written(.blobHave)
        #expect(Set(queries.compactMap(\.to)) == [hop.nodeId, other.nodeId], "both neighbours are asked whether they hold it")
        for query in queries {
            let peer = query.to == hop.nodeId ? hop : other
            iphone.deliver(peer.blobHas([BlobHasItem(hash: hash.string, state: .notHeld)], re: query.envelope.id), from: peer)
        }
        #expect(iphone.transport.written(.blobRequest).map(\.to) == [hop.nodeId], "the first pull-through asks the hop alone")
    }

    /// A copy whose unit failed although its DM was delivered before: after our reset its era drains, so a re-served copy
    /// opens again under the draining root, and the store, failing its reads, lets it past the exists-gate and then
    /// fails its unit. Nothing else commits it, so the sweep's row check is what lets it go, and the DM is not
    /// acknowledged a second time.
    @Test(arguments: StoreKind.allCases)
    func aKeptCopyOfADMDeliveredBeforeIsLetGoByItsRow(kind: StoreKind) throws {
        let directory = scratchDirectory("kept-delivered-before")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let iphone = try EngineFixture.ratcheting(me, stores: stores)
        let android = try AndroidPeer(alice)
        try iphone.pin(android)
        let frame = try android.dm("hello", to: me, prekey: try iphone.ourPrekey(), id: "dm-1", sentAt: now)
        iphone.deliver(frame, from: android)
        #expect(iphone.acknowledged(by: android) == ["dm-1"])
        _ = iphone.engine.drainEvents()
        guard case .sent = iphone.engine.sendRatchetReset(to: alice.nodeId) else {
            Issue.record("our reset goes")
            return
        }

        refusing.failsReads = true
        iphone.deliverPastRouter(frame, from: carol)
        refusing.failsReads = false
        #expect(iphone.engine.dropped[.storeRefused] == 1, "opened again under the draining root, and its unit failed")

        iphone.advance(sweep)
        #expect(receivedRecords(in: iphone.engine.drainEvents()).isEmpty)
        #expect(iphone.acknowledged(by: android) == ["dm-1"], "its row let the copy go, unopened and unacknowledged")
        #expect(iphone.stores.custody.contains("dm-1"), "our sealed receipt purged nothing of ours (phase P5d)")
    }

    /// A sealed receipt, which has no row, whose unit fails: the sweep applies it once, and the next sweep opens nothing.
    @Test(arguments: StoreKind.allCases)
    func aKeptReceiptFlipsItsTickOnceAtTheSweep(kind: StoreKind) throws {
        let directory = scratchDirectory("kept-receipt")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingOpens(blobs: directory, failures: ReportedFailures().record)
        let iphone = try EngineFixture.ratcheting(me, stores: stores)
        let android = try AndroidPeer(alice)
        try iphone.pin(android)
        let ours = try #require(iphone.engine.sendDirectMessage("hi", to: alice.nodeId)).id
        _ = iphone.engine.drainEvents()
        let receipt = MessageContent(body: "", ctl: MessageContent.Control.receipt, ack: ours)
        let frame = try android.dm(receipt, to: me, prekey: try iphone.ourPrekey(), id: "tick-1", sentAt: now)

        refusing.refusesWrites = true
        iphone.deliver(frame, from: android)
        refusing.refusesWrites = false
        #expect(stores.messages.message(ours)?.delivered == false)

        iphone.advance(sweep)
        #expect(stores.messages.message(ours)?.delivered == true)
        #expect(deliveredIds(in: iphone.engine.drainEvents()) == [ours])
        let drops = iphone.engine.dropped
        iphone.advance(sweep)
        #expect(iphone.engine.dropped == drops, "the next sweep opens nothing")
        #expect(deliveredIds(in: iphone.engine.drainEvents()).isEmpty)
    }
}
