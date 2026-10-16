import Foundation
import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// A ratchet DM whose unit failed, against what custody and the blob exchange do around it (ADR 2026-10.5sk9, phase P5a;
/// the tests the blobs reviews owe): the flooded copy both custodies hold, delivered from the copy kept with no carrier
/// serving it again; a sweep that cannot read the row, which keeps the copy instead of losing the frame; a frame
/// delivered another way first; and a photo the DM names, asked for only once its unit commits. The database refuses
/// with SQLite's own refusal (``StoreKind``).
@Suite struct MeshEngineRatchetCustodyTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private var now: Int64 { EngineFixture.start }
    private var sweep: Int64 { MeshConfiguration().sweepMilliseconds }

    /// The common case of shape 11: the iPhone and a carrier both carry the flooded copy, and the iPhone's row is refused.
    /// Linked, their digests agree, so the carrier serves nothing; the sweep delivers the DM from the copy the iPhone kept,
    /// and our cleartext receipt purges it from both.
    @Test func aFloodedCopyWhoseRowWasRefusedIsDeliveredFromTheCopyKeptAndBothCustodiesConverge() throws {
        let directory = scratchDirectory("flooded-copy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try StoreKind.sql.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let iphone = try EngineFixture.ratcheting(me, stores: stores)
        let carrier = EngineFixture(carol)
        let android = try AndroidPeer(alice)
        try iphone.pin(android)
        try carrier.pin(android)
        let frame = try android.dm("hello", to: me, prekey: try iphone.ourPrekey(), id: "dm-1", sentAt: now)
        carrier.deliver(frame, from: android)
        refusing.refusesRows = true
        iphone.deliver(frame, from: android)
        refusing.refusesRows = false
        #expect(iphone.engine.dropped[.storeRefused] == 1)
        #expect(iphone.stores.custody.contains("dm-1") && carrier.stores.custody.contains("dm-1"), "both carry it")
        // Each relays what it took once the router's jitter runs out, before the two meet, as a phone met later would.
        let jitter = Router.Configuration().jitterWindowMilliseconds
        iphone.advance(jitter)
        carrier.advance(jitter)

        iphone.link(carol)
        carrier.link(me)
        var served = exchange(iphone, carrier)
        #expect(iphone.stores.messages.message("dm-1") == nil, "the carrier served nothing that opened it")
        _ = iphone.engine.drainEvents()

        iphone.advance(sweep)
        #expect(iphone.stores.messages.message("dm-1")?.body == "hello", "delivered from the copy kept")
        #expect(receivedRecords(in: iphone.engine.drainEvents()).map(\.id) == ["dm-1"])
        // The carrier's clock keeps step, or our receipt would reach it dated past the five minutes custody allows.
        carrier.advance(sweep)
        served += exchange(iphone, carrier)
        #expect(!served.contains("dm-1"), "the carrier never served it again")
        let ours = Set(iphone.stores.custody.liveIds(now: iphone.clock.wallMilliseconds()))
        let theirs = Set(carrier.stores.custody.liveIds(now: carrier.clock.wallMilliseconds()))
        #expect(ours == theirs, "the custodies differ by \(ours.symmetricDifference(theirs).sorted())")
        #expect(!ours.contains("dm-1") && !theirs.contains("dm-1"), "our cleartext receipt purged it on both")
    }

    /// The blobs reviews' sweep: whether a kept copy is let go is read from its row, in a unit of its own. A read the store
    /// fails there fails the unit and keeps the copy, unopened, for the next sweep, which delivers it.
    @Test(arguments: StoreKind.allCases)
    func aKeptCopyOutlivesASweepThatCannotReadItsRow(kind: StoreKind) throws {
        let directory = scratchDirectory("row-read")
        defer { try? FileManager.default.removeItem(at: directory) }
        let failures = ReportedFailures()
        let (stores, refusing) = try kind.storesRefusingRows(blobs: directory, failures: failures.record)
        let iphone = try EngineFixture.ratcheting(me, stores: stores)
        let android = try AndroidPeer(alice)
        try iphone.pin(android)
        let frame = try android.dm("hello", to: me, prekey: try iphone.ourPrekey(), id: "dm-1", sentAt: now)
        refusing.refusesRows = true
        iphone.deliver(frame, from: android)
        refusing.refusesRows = false
        _ = iphone.engine.drainEvents()
        let reported = failures.count

        refusing.failsReads = true
        iphone.advance(sweep)
        refusing.failsReads = false
        #expect(iphone.stores.messages.message("dm-1") == nil)
        #expect(iphone.engine.dropped[.storeRefused] == 1, "kept, and not opened")
        #expect(kind == .memory || failures.count > reported, "the database reports the read it failed")

        iphone.advance(sweep)
        #expect(iphone.stores.messages.message("dm-1")?.body == "hello", "the next sweep delivers it")
        #expect(receivedRecords(in: iphone.engine.drainEvents()).map(\.id) == ["dm-1"])
        #expect(iphone.acknowledged == ["dm-1"])
    }

    /// A kept frame delivered another way before the sweep, here the copy the router let past once, is delivered and
    /// acknowledged once: that copy's commit lets the kept one go (``RatchetReplay/forget(_:)``), so the sweep opens
    /// nothing.
    @Test(arguments: StoreKind.allCases)
    func aKeptFrameDeliveredBeforeTheSweepIsDeliveredOnce(kind: StoreKind) throws {
        let directory = scratchDirectory("kept-delivered")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let iphone = try EngineFixture.ratcheting(me, stores: stores)
        let android = try AndroidPeer(alice)
        try iphone.pin(android)
        let frame = try android.dm("hello", to: me, prekey: try iphone.ourPrekey(), id: "dm-1", sentAt: now)
        refusing.refusesRows = true
        iphone.deliver(frame, from: android)
        refusing.refusesRows = false

        iphone.deliver(frame, from: carol)
        #expect(iphone.stores.messages.message("dm-1")?.body == "hello", "the copy the router let past once")
        #expect(receivedRecords(in: iphone.engine.drainEvents()).map(\.id) == ["dm-1"])
        iphone.advance(sweep)
        #expect(receivedRecords(in: iphone.engine.drainEvents()).isEmpty)
        #expect(iphone.acknowledged == ["dm-1"])
    }

    /// A ratchet DM naming a photo only the carrier holds: nothing is asked for while its unit fails, since the ask is work
    /// for after the commit, and the replay that commits it asks once, on the one link there is.
    @Test func aPhotoOnlyTheCarrierHoldsIsAskedForOncePerLinkOnceItsUnitCommits() throws {
        let directory = scratchDirectory("carried-photo")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try StoreKind.sql.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let iphone = try EngineFixture.ratcheting(me, stores: stores)
        let android = try AndroidPeer(alice)
        try iphone.pin(android)
        iphone.link(carol)
        let sealed = try #require(AttachmentCrypto.seal(Array("a picture".utf8)))
        let hash = BlobHash(of: sealed.blob)
        let content = MessageContent(
            body: "look", attachmentHash: hash.string, attachmentMime: "image/jpeg", attachmentKey: Base64.encode(sealed.key))
        let frame = try android.dm(content, to: me, prekey: try iphone.ourPrekey(), id: "photo-1", sentAt: now)
        iphone.transport.clear()

        refusing.refusesRows = true
        iphone.deliver(frame, from: carol)
        refusing.refusesRows = false
        #expect(iphone.engine.dropped[.storeRefused] == 1)
        #expect(asks(for: hash, in: iphone).isEmpty, "nothing is asked for while the unit fails")

        iphone.advance(sweep)
        #expect(iphone.stores.messages.message("photo-1")?.attachment?.hash == hash)
        #expect(asks(for: hash, in: iphone) == [carol.nodeId], "one ask, on the one link")
    }

    /// Who `fixture` asked for `hash`, by `blobreq`, in order.
    private func asks(for hash: BlobHash, in fixture: EngineFixture) -> [NodeId?] {
        fixture.transport.written(.blobRequest).filter { written in
            (try? BlobRequestContent(decoding: written.envelope.payload))?.hash == hash.string
        }
        .map(\.to)
    }

    /// Carries what each engine writes to the other until both fall quiet, as a live link between them would
    /// (``MeshEngineRatchetUnitTests``), and answers the ids of the frames `other` wrote.
    private func exchange(_ one: EngineFixture, _ other: EngineFixture) -> [String] {
        var fromOther: [String] = []
        var quiet = false
        while !quiet {
            quiet = true
            for (from, to) in [(one, other), (other, one)] {
                let written = from.transport.written.filter { $0.to == nil || $0.to == to.me.nodeId }
                let digests = from.transport.digests.filter { $0.to == to.me.nodeId }
                from.transport.clear()
                if from.me == other.me {
                    fromOther += written.map(\.envelope.id)
                }
                for frame in written {
                    quiet = false
                    to.engine.receive(InboundFrame(wire: frame.wire, envelope: frame.envelope, from: from.me.nodeId))
                }
                for digest in digests {
                    quiet = false
                    to.engine.receiveDigest(digest.ids, from: from.me.nodeId)
                }
            }
        }
        return fromOther
    }
}
