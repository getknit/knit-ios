import KnitCrypto
import KnitMesh
import KnitWire
import Testing

/// A sealed link's outbox (the `link-seal` contract, §4 and §5): nothing after our KEY_SHARE leaves in the clear, each frame
/// is sealed once as it leaves the queue, and the digest slot and the counts still work on plaintext.
@Suite struct LinkOutboxSealTests {
    /// Writes everything, `limit` bytes at a time, and answers each piece in order.
    private func drain(_ outbox: inout LinkOutbox, limit: Int = 1 << 20) -> [[UInt8]] {
        var pieces: [[UInt8]] = []
        while let piece = outbox.next(atMost: limit) {
            pieces.append(Array(piece))
            outbox.wrote(piece.count)
        }
        return pieces
    }

    /// Both halves of one exchange: what the outbox seals with, and what the far end opens with.
    private static func halves() throws -> (sealer: LinkSealer, opener: LinkOpener) {
        let dialer = LinkSeal.Ephemeral()
        let responder = LinkSeal.Ephemeral()
        let ours = try LinkSeal.derive(dialer, peerShare: responder.keyShare, role: .dialer)
        let theirs = try LinkSeal.derive(responder, peerShare: dialer.keyShare, role: .responder)
        return (ours.sealer, theirs.opener)
    }

    private static let keyShare = LinkRecord(.keyShare, payload: [UInt8](repeating: 0x5E, count: 32)).encoded ?? []

    /// The far end's reading: every outer record, each frame opened in order and its plaintext read as records.
    private static func open(_ bytes: [UInt8], with opener: LinkOpener) throws -> (outer: [LinkRecord.Tag], inner: [LinkRecord]) {
        var outer = LinkRecordReader()
        outer.append(bytes)
        var tags: [LinkRecord.Tag] = []
        var inner = LinkRecordReader()
        while let record = try outer.next() {
            tags.append(record.tag)
            if record.tag == .sealed {
                inner.append(try #require(opener.open(sealedPayload: record.payload), "frame \(tags.count) opens in order"))
            }
        }
        var records: [LinkRecord] = []
        while let record = try inner.next() {
            records.append(record)
        }
        return (tags, records)
    }

    private static func record(_ tag: LinkRecord.Tag, _ fill: UInt8, count: Int) -> [UInt8] {
        LinkRecord(tag, payload: [UInt8](repeating: fill, count: count)).encoded ?? []
    }

    @Test func nothingAfterOurKeyShareLeavesUntilTheSealerComesAndThenOnlyFrames() throws {
        let (sealer, opener) = try Self.halves()
        var outbox = LinkOutbox()
        outbox.appendKeyShare(Self.keyShare)
        let hello = Self.record(.hello, 0x48, count: 40)
        let digest = Self.record(.digest, 0xD1, count: 30)
        outbox.append(hello)
        outbox.offerDigest(digest)
        #expect(drain(&outbox).flatMap(\.self) == Self.keyShare, "the KEY_SHARE alone, the HELLO and digest held")
        #expect(outbox.awaitsSealer)
        #expect(!outbox.isEmpty)
        outbox.seal(with: sealer)
        let read = try Self.open(drain(&outbox).flatMap(\.self), with: opener)
        #expect(read.outer.allSatisfy { $0 == .sealed }, "nothing but frames after the KEY_SHARE")
        #expect(read.inner.map(\.tag) == [.hello, .digest])
        #expect(outbox.isEmpty)
        #expect(outbox.queuedBytes == 0)
    }

    @Test func aDigestReplacedBehindABackedUpQueueStillOpensInOrder() throws {
        let (sealer, opener) = try Self.halves()
        var outbox = LinkOutbox()
        outbox.appendKeyShare(Self.keyShare)
        outbox.seal(with: sealer)
        let backfill = Self.record(.frame, 0x07, count: 20_000)
        outbox.append(backfill)
        outbox.offerDigest(Self.record(.digest, 0xD1, count: 100))
        let live = Self.record(.frame, 0x01, count: 10)
        outbox.append(live)
        // The writer takes part of the back-fill: sealed frames are under way, and the digest is still only queued.
        var aired: [UInt8] = []
        for _ in 0..<3 {
            let nextSlice = outbox.next(atMost: 100)
            let next = try #require(nextSlice)
            aired += next
            outbox.wrote(next.count)
        }
        let replaced = outbox.offerDigest(Self.record(.digest, 0xD2, count: 50))
        #expect(replaced, "a digest none of whose bytes are sealed can still be replaced")
        aired += drain(&outbox, limit: 333).flatMap(\.self)
        let read = try Self.open(aired, with: opener)
        #expect(read.outer.first == .keyShare)
        #expect(read.outer.dropFirst().allSatisfy { $0 == .sealed })
        #expect(read.inner.map(\.tag) == [.frame, .digest, .frame])
        #expect(read.inner[1].payload == [UInt8](repeating: 0xD2, count: 50), "the newer digest, in the older one's place")
        #expect(read.inner[2].encoded == live)
    }

    @Test func aDigestWhoseFirstFrameIsSealedIsFixedAndTheNextQueuesBehindIt() throws {
        let (sealer, opener) = try Self.halves()
        var outbox = LinkOutbox()
        outbox.appendKeyShare(Self.keyShare)
        outbox.seal(with: sealer)
        _ = drain(&outbox)
        outbox.offerDigest(Self.record(.digest, 0xA1, count: 20))
        // The radio was offered the frame and could not write it: sealed, so fixed, with no byte out.
        #expect(outbox.next(atMost: 8) != nil)
        outbox.wrote(0)
        let replaced = outbox.offerDigest(Self.record(.digest, 0xB1, count: 20))
        #expect(!replaced)
        let read = try Self.open(drain(&outbox).flatMap(\.self), with: opener)
        #expect(read.inner.map(\.payload.first) == [0xA1, 0xB1])
    }

    @Test func aFrameRefusedByTheSocketIsOfferedAgainAsItWasNeverSealedTwice() throws {
        let (sealer, opener) = try Self.halves()
        var outbox = LinkOutbox()
        outbox.appendKeyShare(Self.keyShare)
        outbox.seal(with: sealer)
        _ = drain(&outbox)
        outbox.append(Self.record(.frame, 0x33, count: 500))
        let firstSlice = outbox.next(atMost: 64)
        let first = try #require(firstSlice)
        let againSlice = outbox.next(atMost: 64)
        let again = try #require(againSlice)
        #expect(first == again, "the same ciphertext: a would-block re-offers, never re-seals")
        let widerSlice = outbox.next(atMost: 4096)
        let wider = try #require(widerSlice)
        #expect(wider.starts(with: first), "a wider write takes more of the same frame")
        let read = try Self.open(drain(&outbox, limit: 7).flatMap(\.self), with: opener)
        #expect(read.inner.map(\.payload.count) == [500])
    }

    @Test func aLargeEntryIsSealedInFramesOfAWriteEachAndCountsPlaintext() throws {
        let (sealer, opener) = try Self.halves()
        var outbox = LinkOutbox()
        outbox.appendKeyShare(Self.keyShare)
        outbox.seal(with: sealer)
        _ = drain(&outbox)
        let file = Self.record(.fileChunk, 0x42, count: 100_000)
        outbox.appendFileRecord(file)
        #expect(outbox.queuedBytes == file.count, "plaintext")
        var pieces: [[UInt8]] = []
        var plaintext = 0
        var finished = 0
        while let piece = outbox.next(atMost: LinkOutbox.sealedFrameBytes) {
            pieces.append(Array(piece))
            let report = outbox.wrote(piece.count)
            plaintext += report.plaintextBytes
            finished += report.finishedFileRecord ? 1 : 0
        }
        #expect(pieces.allSatisfy { $0.count <= LinkOutbox.sealedFrameBytes }, "one frame, one write")
        #expect(plaintext == file.count, "the levels hear plaintext")
        #expect(finished == 1, "reported once, when its last plaintext byte is out")
        let read = try Self.open(pieces.flatMap(\.self), with: opener)
        #expect(read.inner.first?.encoded == file)
    }

    @Test func aFailedSealWritesNothingMoreAndNothingPlain() throws {
        let (sealer, _) = try Self.halves()
        var outbox = LinkOutbox()
        outbox.appendKeyShare(Self.keyShare)
        outbox.seal(with: sealer)
        _ = drain(&outbox)
        _ = sealer.seal([UInt8]()) // poisons the sealer, as the 2^48th frame would
        outbox.append(Self.record(.frame, 0x01, count: 10))
        #expect(outbox.next(atMost: 100) == nil)
        #expect(outbox.sealFailed, "the radio closes the channel")
        outbox.append(Self.record(.frame, 0x02, count: 10))
        #expect(outbox.next(atMost: 100) == nil)
    }

    @Test func droppingASealedQueueNeverTurnsItPlain() throws {
        let (sealer, _) = try Self.halves()
        var outbox = LinkOutbox()
        outbox.appendKeyShare(Self.keyShare)
        outbox.seal(with: sealer)
        outbox.removeAll()
        #expect(outbox.sealFailed)
        outbox.append(Self.record(.frame, 0x01, count: 10))
        #expect(outbox.next(atMost: 100) == nil, "never written in the clear")
        var plain = LinkOutbox()
        plain.removeAll()
        #expect(!plain.sealFailed, "a plain link's queue stays plain")
    }

    @Test func aSecondKeyShareOrSealerFailsTheOutbox() throws {
        let (sealer, _) = try Self.halves()
        var twice = LinkOutbox()
        twice.appendKeyShare(Self.keyShare)
        twice.appendKeyShare(Self.keyShare)
        #expect(twice.sealFailed)
        var resealed = LinkOutbox()
        resealed.appendKeyShare(Self.keyShare)
        resealed.seal(with: sealer)
        resealed.seal(with: sealer)
        #expect(resealed.sealFailed)
    }

    @Test func theBitFlipLeavesTheHeaderAndBreaksTheFrame() throws {
        let (sealer, opener) = try Self.halves()
        var outbox = LinkOutbox()
        outbox.appendKeyShare(Self.keyShare)
        outbox.seal(with: sealer)
        _ = drain(&outbox)
        outbox.corruptNextSealedFrame()
        outbox.append(Self.record(.frame, 0x01, count: 10))
        var reader = LinkRecordReader()
        reader.append(drain(&outbox).flatMap(\.self))
        let frame = try #require(try reader.next())
        #expect(frame.tag == .sealed, "the far end still reads a frame")
        #expect(opener.open(sealedPayload: frame.payload) == nil, "and fails to open it")
    }
}
