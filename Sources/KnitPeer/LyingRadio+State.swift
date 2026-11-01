import KnitMesh
import KnitWire

/// ``LyingRadio``'s state, kept under its lock, and the steps that write through it: the held record rewritten, and what
/// waits on a ready channel injected.
extension LyingRadio {
    /// One channel as the radio sees it.
    struct Link {
        /// Bytes still to come of a record passing through.
        var unfinished = 0
        /// The slices of a record held for a rewrite, and the bytes of it still to come.
        var held: [[UInt8]] = []
        var heldLeft = 0
        /// Whether our HELLO went out, and whom the link manager registered the link to.
        var wroteHello = false
        var peer: NodeId?
        /// When the channel became ready, in the order channels do: the newest to a peer takes its asks.
        var readyAt: UInt64?
        /// The id of the forge written here.
        var forged: String?
        /// Asks waiting for the next record boundary.
        var asks: [Ask] = []

        var atBoundary: Bool { unfinished == 0 && heldLeft == 0 }
    }

    /// A one-shot ask waiting to be written.
    struct Ask {
        var hash: BlobHash
        var wire: WireEnvelope
    }

    struct State {
        var links: [ChannelID: Link] = [:]
        /// Channels the radio or the link manager closed: a write that still comes for one passes through untracked, so
        /// no entry for it is made again after its link was forgotten.
        var closed: Set<ChannelID> = []
        var readyCount: UInt64 = 0
        var sizes: [BlobHash: Int64] = [:]
        /// Each junk hash's declared size, `nil` for a header with none.
        var declared: [BlobHash: Int?] = [:]
        var forge: Forge?
        var counts = Counts()
        var random: any RandomNumberGenerator & Sendable

        /// Whether a record with `tag` might be rewritten, so its slices are held until it is whole.
        func holds(_ tag: LinkRecord.Tag, advertised: BlobHash?) -> Bool {
            switch tag {
            case .frame:
                !sizes.isEmpty
            case .fileHeader:
                !declared.isEmpty || advertised != nil
            default:
                false
            }
        }
    }

    /// What a locked step leaves to do once the lock is released: rings and log lines.
    struct Effects {
        var rings: [ChannelID] = []
        var lines: [String] = []
    }

    /// The first slice of a record: held when `holding` says its tag might be rewritten, and otherwise written, a HELLO
    /// marked as ours. A slice shorter than a header, or with no tag of the eight, is a whole write, as the flood reads one.
    func begin(_ bytes: [UInt8], of link: inout Link, on channel: ChannelID, holding: (LinkRecord.Tag) -> Bool) {
        guard let head = LyingRecords.header(of: bytes) else {
            inner.write(bytes, to: channel)
            return
        }
        guard !holding(head.tag) else {
            link.held = [bytes]
            link.heldLeft = max(0, head.total - bytes.count)
            return
        }
        link.unfinished = max(0, head.total - bytes.count)
        inner.write(bytes, to: channel)
        if head.tag == .hello {
            link.wroteHello = true
        }
    }

    /// Writes the record `link` held, rewritten when a lie applies, in slices no larger than the first one held; as it
    /// came when none does.
    func writeHeld(_ link: inout Link, on channel: ChannelID, in state: inout State, advertised: BlobHash?, effects: inout Effects) {
        let slices = link.held
        link.held = []
        let bytes = slices.flatMap(\.self)
        var rewritten: LinkRecord?
        if let record = LyingRecords.whole(bytes) {
            switch record.tag {
            case .frame:
                rewritten = rewrittenFrame(record, on: channel, in: &state, effects: &effects)
            case .fileHeader:
                rewritten = rewrittenHeader(record, on: channel, in: &state, advertised: advertised, effects: &effects)
            default:
                break
            }
        }
        guard let encoded = rewritten?.encoded else {
            for slice in slices {
                inner.write(slice, to: channel)
            }
            return
        }
        writeSliced(encoded, on: channel, slice: max(1, slices.first?.count ?? Self.sliceBytes))
    }

    /// A FRAME carrying our `blobhas` answer, claiming what ``State/sizes`` says, or `nil` when it carries none.
    func rewrittenFrame(_ record: LinkRecord, on channel: ChannelID, in state: inout State, effects: inout Effects) -> LinkRecord? {
        guard let lie = LyingRecords.blobHasAnswer(record, sizes: state.sizes) else {
            return nil
        }
        state.counts.blobhasRewritten += 1
        effects.lines.append("lying: blobhas answer on \(channel) claims \(lie.hashes.map(\.string).joined(separator: ","))")
        return lie.record
    }

    /// An `ATTACHMENT` header for a junk hash with its size declared as set, or `nil` for any other header. An `AVATAR`
    /// header for the advertised photo is counted and left as it is.
    func rewrittenHeader(
        _ record: LinkRecord, on channel: ChannelID, in state: inout State, advertised: BlobHash?, effects: inout Effects
    ) -> LinkRecord? {
        switch LyingRecords.fileHeader(record, declared: state.declared, advertised: advertised) {
        case .advertisedPhoto(let hash):
            state.counts.advertisedPhotoPushed += 1
            effects.lines.append("lying: AVATAR push of the advertised photo \(hash.string) on \(channel)")
            return nil
        case .declared(let rewritten, let header):
            state.counts.junkHeadersRewritten += 1
            let declared = header.size.map { "\($0) bytes" } ?? "no size"
            effects.lines.append(
                "lying: FILE header for \(header.key) on \(channel) declares \(declared)" + (header.offset.map { " from \($0)" } ?? ""))
            return rewritten
        case .honest:
            return nil
        }
    }

    /// Writes `record` in slices of at most `slice` bytes.
    func writeSliced(_ record: [UInt8], on channel: ChannelID, slice: Int) {
        var start = 0
        while start < record.count {
            let end = min(start + slice, record.count)
            inner.write(Array(record[start..<end]), to: channel)
            start = end
        }
    }

    // MARK: Injection

    /// At a record boundary on a ready channel, writes what waits there: the forge, when the channel lacks it, then the
    /// asks. Marks the channel ready the first time both its HELLOs are in.
    func catchUp(_ channel: ChannelID, in state: inout State, effects: inout Effects) {
        guard var link = state.links[channel], link.wroteHello, let peer = link.peer, link.atBoundary else {
            return
        }
        if link.readyAt == nil {
            state.readyCount += 1
            link.readyAt = state.readyCount
        }
        var wrote = false
        if let forge = state.forge, link.forged != forge.id, let record = LinkRecord(.frame, payload: forge.wire.encoded).encoded {
            writeSliced(record, on: channel, slice: Self.sliceBytes)
            link.forged = forge.id
            state.counts.forgedProfilesWritten[peer, default: 0] += 1
            effects.lines.append(
                "lying: padded profile \(forge.id) of \(forge.wire.signed.count) signed bytes written to \(peer) on \(channel)")
            wrote = true
        }
        for ask in link.asks {
            if let record = LinkRecord(.frame, payload: ask.wire.encoded).encoded {
                writeSliced(record, on: channel, slice: Self.sliceBytes)
                state.counts.blobAsksSent[peer, default: 0] += 1
                effects.lines.append("lying: blobreq for \(ask.hash.string) written to \(peer) on \(channel)")
                wrote = true
            }
        }
        link.asks = []
        state.links[channel] = link
        if wrote {
            effects.rings.append(channel)
        }
    }

    func apply(_ effects: Effects) {
        for line in effects.lines {
            log.log(.info, line)
        }
        for channel in effects.rings {
            inner.ring(channel)
        }
    }
}
