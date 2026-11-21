import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitCrypto
@testable import KnitMesh

/// One link between two ``PipeNode``s: the bytes each radio writes are read back as records and handed to the other, record
/// by record, with the radio's report of each FILE record as it crosses. It records what it carried, and can be cut after
/// some bytes of a file, as a link at the edge of range is: both channels close, and each side's teardown keeps what it
/// had (`LinkManager.retire`). One channel each side for the pipe's life, so one intake, and the #161 window, per link.
final class LinkPipe {
    /// A file header that crossed, holder to asker, and when.
    struct Serve: Equatable {
        var from: NodeId
        var to: NodeId
        var hash: BlobHash
        var offset: Int?
        var at: Int64
    }

    /// A `blobreq` that crossed, and when.
    struct Ask: Equatable {
        var from: NodeId
        var to: NodeId
        var hash: String
        var offset: Int64?
        var at: Int64
    }

    /// A FRAME record that crossed, and when.
    struct Frame: Equatable {
        var from: NodeId
        var to: NodeId
        var id: String
        var type: FrameType
        /// The record's payload: the encoded `WireEnvelope`.
        var bytes: Int
        var at: Int64
    }

    /// A record read off a radio under ``delay``, its encoded size, and when it may cross.
    private struct InFlight {
        var record: LinkRecord
        var bytes: Int
        var due: Int64
    }

    private struct Side {
        let node: PipeNode
        let channel: ChannelID
        var read = 0
        var reader = LinkRecordReader()
        // While the side's writes are out but unread (``LinkPipe/unread``): how far they were parsed, and how many FILE
        // records each way of reporting has reported, so a record is reported written once, whichever reports it first.
        var aired = 0
        var airReader = LinkRecordReader()
        var airedFileRecords = 0
        var deliveredFileRecords = 0
        // Records read off the side's radio that have not crossed yet, under ``LinkPipe/delay``, each with when it may.
        var inFlight: [InFlight] = []
        // On a sealed pipe: the opener for what this side writes, and the records its frames' plaintext holds.
        var opener: LinkOpener?
        var inner = LinkRecordReader()
        // Under ``LinkPipe/bytesPerSecond``: what the air has not carried yet, what it may by now, when, and all it carried.
        var unwritten: [LinkRecord] = []
        var allowance: Int64 = 0
        var airedAt: Int64 = 0
        var writtenBytes: Int64 = 0
    }

    private var sides: [Side]
    private let clock: ManualClock
    /// When set, the pipe is cut once this many bytes of FILE_CHUNK have crossed it, either way.
    var cutAfter: Int?
    private(set) var isUp = true
    /// The FILE_CHUNK bytes it carried, either way.
    private(set) var chunkBytes = 0
    private(set) var serves: [Serve] = []
    private(set) var asks: [Ask] = []
    /// Every FRAME record it carried, either way, its envelope decoded.
    private(set) var frames: [Frame] = []
    /// A DIGEST record that crossed: who sent it, how many ids it listed, and when.
    struct Digest: Equatable {
        var from: NodeId
        var ids: Int
        var at: Int64
    }

    /// Every DIGEST record it carried, either way.
    private(set) var digests: [Digest] = []
    /// When set, what this node writes waits on its radio, unread, as on a link whose air is slow: nothing it writes
    /// crosses, and no FILE record it writes is reported written, until this is cleared.
    var holding: PipeNode?
    /// When set, what this node writes leaves its radio but the far side never reads it, as on a stalled reader: each FILE
    /// record is reported written at once, nothing crosses until cleared, so a feed runs on where ``holding`` stops it.
    var unread: PipeNode?
    /// When set, what the node writes crosses this many ms after the pipe first sees it, each FILE record reported written
    /// at once, as on a long round trip: a feed's window grows to cover it. ``unread`` then stops even what is under way.
    var delay: (node: PipeNode, milliseconds: Int64)?

    /// Whether the link opened sealed. A sealed pipe carries each side's outer records, KEY_SHAREs and frames, as the radio
    /// wrote them, and reads inside them with keys of its own: both nodes make their ephemeral keys from scalars the pipe
    /// knows (``LinkManager/makeEphemeral``), so it derives the same sessions and opens every frame in order. Its records,
    /// serves, asks, file reports, holds and cuts are then a plain pipe's; ``unread``, ``delay`` and ``inject(_:from:)`` are
    /// a plain pipe's alone.
    let sealed: Bool

    /// Links `dialer` and `answerer` on `channel`, each side its own channel number: the dialer's dial opens, as though
    /// promotion had made it, and writes its HELLO; the answerer accepts. The handshake crosses at the next pump: the HELLO,
    /// the answer and its PROOF, then the dialer's PROOF, so each side registers the other only once its proof verified.
    ///
    /// A plain pipe, the default, reads every record that crosses, so both nodes run with the seal switched off, as Android
    /// v2.11.0 does: two sealing builds refuse a plain link (the `link-seal` contract, §7). A `sealed` pipe dials as an advert
    /// carrying `FLAG_LINK_SEAL` makes it: KEY_SHAREs, then frames, sealed by each radio's own outbox.
    init(_ dialer: PipeNode, _ answerer: PipeNode, channel: UInt64, clock: ManualClock, sealed: Bool = false) {
        self.clock = clock
        self.sealed = sealed
        if !sealed {
            dialer.links.sealSwitch = .off
            answerer.links.sealSwitch = .off
        }
        let dialed = ChannelID(channel)
        sides = [Side(node: dialer, channel: dialed), Side(node: answerer, channel: ChannelID(channel + 1))]
        if sealed {
            let scalars = Self.scalars(channel)
            dialer.links.makeEphemeral = { required(LinkSeal.Ephemeral(scalar: scalars.dialer)) }
            answerer.links.makeEphemeral = { required(LinkSeal.Ephemeral(scalar: scalars.responder)) }
            let dialerShare = required(LinkSeal.Ephemeral(scalar: scalars.dialer)).keyShare
            let responderShare = required(LinkSeal.Ephemeral(scalar: scalars.responder)).keyShare
            // The responder's session opens what the dialer writes, and the dialer's what the responder writes.
            sides[0].opener = try? LinkSeal.derive(
                required(LinkSeal.Ephemeral(scalar: scalars.responder)), peerShare: dialerShare, role: .responder
            ).opener
            sides[1].opener = try? LinkSeal.derive(
                required(LinkSeal.Ephemeral(scalar: scalars.dialer)), peerShare: responderShare, role: .dialer
            ).opener
        }
        let now = clock.monotonicMilliseconds()
        let peer = SightingKey.node(answerer.nodeId)
        let target = LinkManager.DialTarget(
            key: .peer(peer),
            form: .clear(answerer.nodeId),
            address: RadioAddress("pipe"),
            record: DialRecord(kind: .ordinary, peerKey: peer, linkedAtStart: false),
            seals: sealed
        )
        dialer.links.channels[dialed] = LinkManager.Channel(role: .dialer(target), stage: .connecting, deadline: now)
        dialer.links.dialing[target.key] = dialed
        dialer.apply(dialer.links.handle(.connected(dialed)))
        answerer.apply(answerer.links.handle(.accepted(ChannelID(channel + 1))))
    }

    /// When set, each side's air carries this many bytes a second, a record at a time, and its radio reports what waits as
    /// queued (``Radio/outboxLevel(on:)``), which custody's rounds wait on. Set once the link is up.
    var bytesPerSecond: Int? {
        didSet {
            for index in sides.indices { sides[index].airedAt = clock.monotonicMilliseconds() }
        }
    }

    /// Carries what is waiting either way, once. Answers whether anything crossed.
    func pumpOnce() -> Bool {
        guard isUp else {
            return false
        }
        if sealed {
            return pumpSealed()
        }
        var moved = false
        let now = clock.monotonicMilliseconds()
        for index in sides.indices where sides[index].node !== holding {
            let writes = sides[index].node.radio.writes(on: sides[index].channel)
            let delayed = delay.flatMap { $0.node === sides[index].node ? $0.milliseconds : nil }
            if sides[index].node === unread || delayed != nil {
                moved = air(writes, from: index) || moved
            }
            if sides[index].node === unread {
                continue
            }
            if sides[index].read < writes.count {
                for write in writes[sides[index].read...] {
                    sides[index].reader.append(write[...])
                }
                sides[index].read = writes.count
            }
            moved = carry(index, delayed: delayed, now: now) || moved
        }
        return moved
    }

    private func deliver(_ record: LinkRecord, from index: Int) {
        sides[1 - index].node.receive(record.encoded ?? [], on: sides[1 - index].channel)
        noteCrossed(record, from: index)
    }

    /// Logs `record`, which crossed from side `index`, reports a FILE record written to its sender, and cuts the pipe once
    /// enough FILE_CHUNK bytes crossed.
    private func noteCrossed(_ record: LinkRecord, from index: Int) {
        let sender = sides[index]
        let receiver = sides[1 - index]
        let now = clock.monotonicMilliseconds()
        if record.tag == .digest {
            digests.append(Digest(from: sender.node.nodeId, ids: LinkJSON.digestIds(from: record.payload)?.count ?? 0, at: now))
        }
        if record.tag == .fileHeader, let header = LinkJSON.fileHeader(from: record.payload), let hash = BlobHash(header.key) {
            serves.append(Serve(from: sender.node.nodeId, to: receiver.node.nodeId, hash: hash, offset: header.offset, at: now))
        }
        if record.tag == .frame, let crossed = Self.frame(record, from: sender.node, to: receiver.node, at: now) {
            frames.append(crossed)
        }
        if record.tag == .frame, let ask = Self.ask(in: record.payload) {
            asks.append(Ask(from: sender.node.nodeId, to: receiver.node.nodeId, hash: ask.hash, offset: ask.offset, at: now))
        }
        guard [.fileHeader, .fileChunk, .fileEnd].contains(record.tag) else {
            return
        }
        sides[index].deliveredFileRecords += 1
        if sides[index].deliveredFileRecords > sides[index].airedFileRecords {
            sender.node.apply(sender.node.links.handle(.wroteFileRecord(sender.channel)))
        }
        if record.tag == .fileChunk {
            chunkBytes += record.payload.count
            if let cutAfter, chunkBytes >= cutAfter {
                cut()
            }
        }
    }

    /// Reports each FILE record among the side's new `writes` written, delivering nothing. Answers whether any was.
    private func air(_ writes: [[UInt8]], from index: Int) -> Bool {
        guard sides[index].aired < writes.count else {
            return false
        }
        for write in writes[sides[index].aired...] {
            sides[index].airReader.append(write[...])
        }
        sides[index].aired = writes.count
        var reported = false
        while let record = try? sides[index].airReader.next() {
            guard [.fileHeader, .fileChunk, .fileEnd].contains(record.tag) else {
                continue
            }
            sides[index].airedFileRecords += 1
            if sides[index].airedFileRecords > sides[index].deliveredFileRecords {
                reported = true
                sides[index].node.apply(sides[index].node.links.handle(.wroteFileRecord(sides[index].channel)))
            }
        }
        return reported
    }

    /// Hands `record` to the far side of `node` as if `node` had written it, recorded as anything that crossed is: a
    /// peer that writes what its engine never would.
    func inject(_ record: LinkRecord, from node: PipeNode) {
        guard isUp, let index = sides.firstIndex(where: { $0.node === node }) else {
            return
        }
        deliver(record, from: index)
    }

    /// The bytes `node` wrote that have not crossed yet.
    func undelivered(from node: PipeNode) -> Int {
        guard let side = sides.first(where: { $0.node === node }) else {
            return 0
        }
        return side.node.radio.writes(on: side.channel).dropFirst(side.read).reduce(0) { $0 + $1.count }
            + side.inFlight.reduce(0) { $0 + $1.bytes } + side.unwritten.reduce(0) { $0 + ($1.encoded?.count ?? 0) }
    }

    /// Whether each side registered the other: the handshake crossed, proofs and all.
    var isLinked: Bool {
        let ids = sides.map(\.node.nodeId)
        return sides[0].node.links.neighbors.contains { $0.nodeId == ids[1] }
            && sides[1].node.links.neighbors.contains { $0.nodeId == ids[0] }
    }

    /// The channel `node` reads this pipe on.
    func channel(of node: PipeNode) -> ChannelID? {
        sides.first { $0.node === node }?.channel
    }

    /// The frame a FRAME record carries, as it crossed from `sender` to `receiver`, if its envelope decodes.
    private static func frame(_ record: LinkRecord, from sender: PipeNode, to receiver: PipeNode, at now: Int64) -> Frame? {
        guard let wire = try? WireEnvelope(decoding: record.payload), let envelope = try? RelayEnvelope(decoding: wire.signed) else {
            return nil
        }
        return Frame(from: sender.nodeId, to: receiver.nodeId, id: envelope.id, type: envelope.type, bytes: record.payload.count, at: now)
    }

    /// The `blobreq` a FRAME record carries, if it is one.
    private static func ask(in payload: [UInt8]) -> BlobRequestContent? {
        guard let wire = try? WireEnvelope(decoding: payload), let envelope = try? RelayEnvelope(decoding: wire.signed),
            envelope.type == .blobRequest
        else {
            return nil
        }
        return try? BlobRequestContent(decoding: envelope.payload)
    }

    /// Closes both ends, as a link that dies does.
    func cut() {
        guard isUp else {
            return
        }
        isUp = false
        for side in sides {
            side.node.apply(side.node.links.handle(.closed(side.channel)))
        }
    }
}

extension LinkPipe {
    /// Two fixed X25519 scalars for the pipe on `channel`, one per role.
    private static func scalars(_ channel: UInt64) -> (dialer: [UInt8], responder: [UInt8]) {
        let base = UInt8(truncatingIfNeeded: channel)
        return ((0..<32).map { 0x40 &+ base &+ UInt8($0) }, (0..<32).map { 0xA0 &+ base &+ UInt8($0) })
    }

    /// Carries each side's outer records across as the radio wrote them, frame by frame, and logs what each frame's
    /// plaintext finished, as a plain pipe logs its records.
    func pumpSealed() -> Bool {
        var moved = false
        for index in sides.indices where sides[index].node !== holding {
            let writes = sides[index].node.radio.writes(on: sides[index].channel)
            if sides[index].read < writes.count {
                for write in writes[sides[index].read...] {
                    sides[index].reader.append(write[...])
                }
                sides[index].read = writes.count
            }
            while isUp, let outer = try? sides[index].reader.next() {
                moved = true
                let receiver = sides[1 - index]
                receiver.node.receive(outer.encoded ?? [], on: receiver.channel)
                guard outer.tag == .sealed, let plaintext = sides[index].opener?.open(sealedPayload: outer.payload) else {
                    continue
                }
                sides[index].inner.append(plaintext)
                while isUp, let record = try? sides[index].inner.next() {
                    noteCrossed(record, from: index)
                }
            }
        }
        return moved
    }
}

extension LinkPipe {
    /// Carries what side `index`'s air can by `now` at `rate` bytes a second, whole records in order; reports what waits.
    private func drain(_ index: Int, rate: Int, now: Int64) -> Bool {
        sides[index].unwritten.append(contentsOf: sides[index].inFlight.map(\.record))
        sides[index].inFlight.removeAll()
        while let record = try? sides[index].reader.next() {
            sides[index].unwritten.append(record)
        }
        sides[index].allowance += Int64(rate) * (now - sides[index].airedAt) / 1000
        sides[index].airedAt = now
        var moved = false
        while isUp, let first = sides[index].unwritten.first, Int64(first.encoded?.count ?? 0) <= sides[index].allowance {
            sides[index].unwritten.removeFirst()
            let bytes = Int64(first.encoded?.count ?? 0)
            sides[index].allowance -= bytes
            sides[index].writtenBytes += bytes
            moved = true
            deliver(first, from: index)
        }
        if sides[index].unwritten.isEmpty {
            sides[index].allowance = 0
        }
        let queued = sides[index].unwritten.reduce(0) { $0 + ($1.encoded?.count ?? 0) }
        sides[index].node.radio.setLevel(
            OutboxLevel(queuedBytes: queued, writtenBytes: sides[index].writtenBytes), on: sides[index].channel)
        return moved
    }

    /// Carries the records side `index` wrote that its air lets cross by `now`: all at once, after `delayed` ms, or at
    /// ``bytesPerSecond``. Answers whether anything crossed.
    private func carry(_ index: Int, delayed: Int64?, now: Int64) -> Bool {
        if let rate = bytesPerSecond, delayed == nil {
            return drain(index, rate: rate, now: now)
        }
        var moved = false
        while isUp, let record = try? sides[index].reader.next() {
            if let delayed {
                sides[index].inFlight.append(InFlight(record: record, bytes: record.encoded?.count ?? 0, due: now + delayed))
            } else {
                moved = true
                deliver(record, from: index)
            }
        }
        while isUp, let first = sides[index].inFlight.first, first.due <= now {
            sides[index].inFlight.removeFirst()
            moved = true
            deliver(first.record, from: index)
        }
        return moved
    }
}
