import Foundation
import KnitCrypto
import KnitStore
import KnitStoreSQL
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A ratchet frame's open and everything it carries commit in one store unit, outermost, that fails closed (ADR
/// 2026-10.5sk9, phase P5a): the tests the P4a reviews owed, over the memory stores, whose unit a refusing store fails, and
/// over the database, which SQLite's own refusal fails. A failed unit delivers and acknowledges nothing, moves no chain,
/// and the copy that failed opens on the replay; the router's dedup is not what stands in its way.
@Suite struct MeshEngineRatchetUnitTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private var now: Int64 { EngineFixture.start }

    @Test(arguments: StoreKind.allCases)
    func aRowTheStoreRefusesDeliversNothingAndOpensOnTheReplay(kind: StoreKind) throws {
        let directory = scratchDirectory("refused-row")
        defer { try? FileManager.default.removeItem(at: directory) }
        let failures = ReportedFailures()
        let (stores, refusing) = try kind.storesRefusingRows(blobs: directory, failures: failures.record)
        let fixture = try EngineFixture.ratcheting(me, stores: stores)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        let frame = try android.dm("hello", to: me, prekey: try fixture.ourPrekey(), id: "dm-1", sentAt: now)

        refusing.refusesRows = true
        fixture.deliver(frame, from: android)
        #expect(fixture.engine.dropped[.storeRefused] == 1)
        #expect(fixture.stores.messages.message("dm-1") == nil)
        #expect(receivedRecords(in: fixture.engine.drainEvents()).isEmpty, "nothing delivered")
        #expect(fixture.transport.written.isEmpty, "nothing acknowledged")
        #expect(fixture.ratchetRecords(of: alice).session == nil, "the chain did not move")
        #expect(fixture.stores.custody.contains("dm-1"), "carried before its unit opened, so in our digest and ours to open")
        #expect(kind == .memory || failures.count == 1, "the database reports its refusal once")

        // The sweep replays it while the store still refuses: kept again, and nothing more.
        fixture.advance(MeshConfiguration().sweepMilliseconds)
        #expect(fixture.engine.dropped[.storeRefused] == 2)
        #expect(fixture.stores.messages.message("dm-1") == nil)

        refusing.refusesRows = false
        fixture.advance(MeshConfiguration().sweepMilliseconds)
        #expect(fixture.stores.messages.message("dm-1")?.body == "hello")
        #expect(receivedRecords(in: fixture.engine.drainEvents()).map(\.id) == ["dm-1"])
        #expect(fixture.acknowledged(by: android) == ["dm-1"])
        #expect(fixture.ratchetRecords(of: alice).session?.confirmed == true)

        fixture.advance(MeshConfiguration().sweepMilliseconds)
        #expect(receivedRecords(in: fixture.engine.drainEvents()).isEmpty, "delivered exactly once")
        #expect(fixture.acknowledged(by: android) == ["dm-1"])
    }

    /// A photo whose bytes this phone holds but cannot read: the DM's unit commits and the DM is delivered once, and the
    /// file's error is reported and fails nothing. The blob is read only after the commit, when the message learns its
    /// plaintext's name (`notePlainHash`), so no `nil` from a blob's bytes decides anything inside the unit.
    @Test func anUnreadablePhotoDeliversItsDMOnceAndFailsNothing() throws {
        let directory = scratchDirectory("unreadable-photo")
        defer { try? FileManager.default.removeItem(at: directory) }
        let failures = ReportedFailures()
        let (stores, _) = try StoreKind.sql.storesRefusingRows(blobs: directory, failures: failures.record)
        let fixture = try EngineFixture.ratcheting(me, stores: stores)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()

        let sealed = try #require(AttachmentCrypto.seal(Array("a picture".utf8)))
        let hash = BlobHash(of: sealed.blob)
        #expect(fixture.stores.blobs.insert(sealed.blob, hash: hash, mime: "image/jpeg", storedAt: now))
        try FileManager.default.removeItem(at: directory.appending(path: hash.string))
        let before = failures.count

        let content = MessageContent(
            body: "look", attachmentHash: hash.string, attachmentMime: "image/jpeg", attachmentKey: Base64.encode(sealed.key))
        let frame = try android.dm(content, to: me, prekey: try fixture.ourPrekey(), id: "photo-1", sentAt: now)
        fixture.deliver(frame, from: android)
        #expect(fixture.engine.dropped[.storeRefused] == nil, "a blob's file error fails no unit")
        #expect(fixture.stores.messages.message("photo-1")?.attachment?.hash == hash)
        #expect(receivedRecords(in: fixture.engine.drainEvents()).map(\.id) == ["photo-1"])
        #expect(fixture.acknowledged(by: android) == ["photo-1"])
        #expect(failures.count == before + 1, "the file's error is reported")

        fixture.deliverPastRouter(frame, from: alice)
        #expect(receivedRecords(in: fixture.engine.drainEvents()).isEmpty, "delivered once")
    }

    /// Crypto reviewer's shape 11 and blobs reviewer's: a copy handed to us point to point never reaches our custody, so
    /// when its unit fails our digest lacks it and a carrier's back-fill brings it again, under the id our router saw. Let
    /// past the router once, it is delivered, carried, and acknowledged, and both custodies hold the same live ids: the DM
    /// and our receipt, which is sealed (phase P5d) and purges nothing.
    @Test(arguments: StoreKind.allCases)
    func aFailedUnitsFrameComesBackInTheNextBackFillAndCustodyConverges(kind: StoreKind) throws {
        let directory = scratchDirectory("back-fill")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let iphone = try EngineFixture.ratcheting(me, stores: stores)
        let carrier = EngineFixture(carol)
        let android = try AndroidPeer(alice)
        try iphone.pin(android)
        try carrier.pin(android)
        let frame = try android.dm("hello", to: me, prekey: try iphone.ourPrekey(), id: "dm-1", sentAt: now)
        carrier.deliver(frame, from: android)
        #expect(carrier.stores.custody.contains("dm-1"))

        // Alice hands it to us point to point, as a phone linked to its addressee does (ADR 2026-09.wkbk), while our
        // store refuses the row.
        refusing.refusesRows = true
        let handed = TestFrame(wire: WireEnvelope(relay: false, sig: frame.wire.sig, signed: frame.wire.signed), envelope: frame.envelope)
        iphone.deliver(handed, from: android)
        #expect(iphone.engine.dropped[.storeRefused] == 1)
        #expect(!iphone.stores.custody.contains("dm-1"), "point to point, so never carried")
        refusing.refusesRows = false
        _ = iphone.engine.drainEvents()

        iphone.link(carol)
        carrier.link(me)
        exchange(iphone, carrier)
        #expect(iphone.stores.messages.message("dm-1")?.body == "hello")
        #expect(receivedRecords(in: iphone.engine.drainEvents()).map(\.id) == ["dm-1"])
        let ours = Set(iphone.stores.custody.liveIds(now: now))
        let theirs = Set(carrier.stores.custody.liveIds(now: now))
        #expect(ours == theirs, "the custodies differ by \(ours.symmetricDifference(theirs).sorted())")
        #expect(ours.contains("dm-1") && theirs.contains("dm-1"), "our sealed receipt purged it nowhere, ours included")
    }

    /// Carries what each engine writes to the other until both fall quiet, as a live link between them would
    /// (`MeshEngineBacklogTests`): link-up pushes, digests, back-fill and our receipts all go out at once.
    private func exchange(_ one: EngineFixture, _ other: EngineFixture) {
        var quiet = false
        while !quiet {
            quiet = true
            for (from, to) in [(one, other), (other, one)] {
                let written = from.transport.written.filter { $0.to == nil || $0.to == to.me.nodeId }
                let digests = from.transport.digests.filter { $0.to == to.me.nodeId }
                from.transport.clear()
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
    }
}
