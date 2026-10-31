public import KnitWire

/// knit-peer's lie about a blob's size, a trial's switch: a `blobhas` answer rewritten on its way out so it claims the
/// hashes lied about are held at the sizes set, as a holder that lies about a photo would (`door-cap-lying-peers`, ADR
/// 2026-10.r88m). The radio wrapper runs every frame it writes through here while the switch is set.
///
/// Only our own answer is touched: unsigned, point to point, of type `blobhas`, its payload a ``BlobHasContent``. A hash
/// the asker did not ask about is never added, since an asker drops an answer to a hash it never queried. Being unsigned,
/// the answer can be re-encoded freely; its routing counters, id, sender, `re` and `load` stay as they were.
public enum BlobHasLie {
    /// `wire` with each item whose hash is in `sizes` claiming that size: a SENDING item keeps its state and its `eta`,
    /// and any other state becomes HAVE. Answers the hashes rewritten with the frame, or `nil` when there is nothing to
    /// rewrite (another type, a signed or relayed frame, a payload that does not decode, or no hash lied about), so the
    /// caller writes the frame's bytes as they were.
    public static func rewrite(_ wire: WireEnvelope, sizes: [BlobHash: Int64]) -> (wire: WireEnvelope, rewritten: [BlobHash])? {
        guard !sizes.isEmpty, wire.sig.isEmpty, !wire.relay, var envelope = try? RelayEnvelope(decoding: wire.signed),
            envelope.type == .blobHas, var answer = try? BlobHasContent(decoding: envelope.payload)
        else {
            return nil
        }
        var rewritten: [BlobHash] = []
        answer.items = answer.items.map { item in
            guard let hash = BlobHash(item.hash), let size = sizes[hash] else {
                return item
            }
            rewritten.append(hash)
            guard item.state == .sending else {
                return BlobHasItem(hash: item.hash, state: .have, size: size)
            }
            var sending = item
            sending.size = size
            return sending
        }
        guard !rewritten.isEmpty else {
            return nil
        }
        envelope.payload = answer.encoded
        var lied = wire
        lied.signed = envelope.encoded
        return (lied, rewritten)
    }
}
