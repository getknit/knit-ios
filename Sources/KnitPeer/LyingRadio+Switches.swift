public import KnitMesh
import KnitSync
public import KnitWire

/// ``LyingRadio``'s switches, which the lying commands set and clear (``PeerLies``).
extension LyingRadio {
    /// The sizes `blobhas` answers claim, by hash.
    public var blobHasLies: [BlobHash: Int64] { state.withLock { $0.sizes } }

    /// The junk hashes whose FILE header is rewritten, each with its declared size, `nil` for none.
    public var junkHeaders: [BlobHash: Int?] { state.withLock { $0.declared } }

    /// The padded profile injected now, or `nil`.
    public var paddedProfile: Forge? { state.withLock { $0.forge } }

    /// What the lies have done so far.
    public var counts: Counts { state.withLock { $0.counts } }

    /// The channels ready for an injection, and the node each one's HELLO named.
    public var readyChannels: [ChannelID: NodeId] {
        state.withLock { state in
            state.links.reduce(into: [:]) { ready, entry in
                if entry.value.readyAt != nil, let peer = entry.value.peer {
                    ready[entry.key] = peer
                }
            }
        }
    }

    /// Our `blobhas` answers claim `hash` held at `size` from now on.
    public func setBlobHasLie(_ hash: BlobHash, size: Int64) {
        state.withLock { $0.sizes[hash] = size }
        log.log(.info, "lying: blobhas answers claim \(hash.string) at \(size) bytes")
    }

    /// Our `blobhas` answers say what the store says of `hash` again.
    public func clearBlobHasLie(_ hash: BlobHash) {
        state.withLock { $0.sizes[hash] = nil }
        log.log(.info, "lying: blobhas answers for \(hash.string) honest again")
    }

    /// An `ATTACHMENT` header for `hash` declares `declare` bytes from now on, or no size when `nil`.
    public func setJunkHeader(_ hash: BlobHash, declare: Int?) {
        state.withLock { $0.declared[hash] = .some(declare) }
        log.log(.info, "lying: FILE headers for \(hash.string) declare \(declare.map { "\($0) bytes" } ?? "no size")")
    }

    /// FILE headers for `hash` go out as written again.
    public func clearJunkHeader(_ hash: BlobHash) {
        state.withLock { _ = $0.declared.removeValue(forKey: hash) }
        log.log(.info, "lying: FILE headers for \(hash.string) honest again")
    }

    /// Injects `forge` once on every ready channel, and on each channel that becomes ready while it is set; `nil` stops.
    /// A channel partway through a record gets it at the record's end. Answers the channels it went out on now.
    @discardableResult
    public func setPaddedProfile(_ forge: Forge?) -> Int {
        let (effects, written) = state.withLock { state -> (Effects, Int) in
            state.forge = forge
            var effects = Effects()
            let before = state.counts.forgedProfilesWritten.values.reduce(0, +)
            for channel in state.links.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                catchUp(channel, in: &state, effects: &effects)
            }
            return (effects, state.counts.forgedProfilesWritten.values.reduce(0, +) - before)
        }
        if forge == nil {
            log.log(.info, "lying: padded profile no longer injected")
        }
        apply(effects)
        return written
    }

    /// Writes one unsigned `blobreq` for `hash` to `peer`, on the newest ready channel whose HELLO named it, between two
    /// records, then rings it, as a plain ask of our own goes (`MeshEngine.blobRequest` and `unsignedPointToPoint`): no
    /// offset, the pull a want of our own mints, no deadline, `sentAt` 0. Our own engine never hears of it. Answers the
    /// ask's id, or `nil` when no ready channel to `peer` took it.
    public func askBlob(_ hash: BlobHash, of peer: NodeId) -> String? {
        let (effects, id) = state.withLock { state -> (Effects, String?) in
            let ready = state.links.filter { $0.value.peer == peer && $0.value.readyAt != nil }
            guard let channel = ready.max(by: { ($0.value.readyAt ?? 0) < ($1.value.readyAt ?? 0) })?.key else {
                return (Effects(), nil)
            }
            let id = FrameId.generate(using: &state.random)
            let content = BlobRequestContent(hash: hash.string, pull: Self.plainAskPull)
            let envelope = RelayEnvelope(type: .blobRequest, id: id, senderId: localId.string, payload: content.encoded)
            state.links[channel]?.asks.append(Ask(hash: hash, wire: WireEnvelope(relay: false, sig: [], signed: envelope.encoded)))
            var effects = Effects()
            catchUp(channel, in: &state, effects: &effects)
            return (effects, id)
        }
        if id == nil {
            log.log(.info, "lying: no ready link to \(peer) for a blobreq of \(hash.string)")
        }
        apply(effects)
        return id
    }
}
