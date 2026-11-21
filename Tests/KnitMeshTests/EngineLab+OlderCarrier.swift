import KnitStore
import KnitWire

@testable import KnitMesh

extension EngineLab {
    /// `carried` in the order a build before the paced rounds served a back-fill: the digests as they came, then profiles,
    /// then everything else newest received first, as `received` lists the carrier's custody.
    static func asAnOlderCarrierServes(_ carried: [EngineLab.Carried], received: [String]) -> [EngineLab.Carried] {
        let rank = Dictionary(received.enumerated().map { (ExactKey($0.element), $0.offset) }) { first, _ in first }
        let digests = carried.filter { $0.id == nil }
        let frames = carried.compactMap { item -> Written? in
            guard case .frame(let frame) = item else {
                return nil
            }
            return frame
        }
        let profiles = frames.filter { $0.envelope.type == .profile }
        let rest = frames.filter { $0.envelope.type != .profile }.sorted { lhs, rhs in
            (rank[ExactKey(lhs.envelope.id)] ?? .max) < (rank[ExactKey(rhs.envelope.id)] ?? .max)
        }
        return digests + (profiles + rest).map(Carried.frame)
    }

    /// Releases what node `from` holds for node `to` in the order a build before the paced rounds served it
    /// (``asAnOlderCarrierServes(_:received:)``, read from `from`'s custody now), with frame `last`, if given, moved last.
    func releaseAsAnOlderCarrier(from: Int, to: Int, last: String? = nil) {
        let received = self[from].stores.custody.liveIndex(now: self[from].clock.wallMilliseconds()).map(\.id)
        release(from: from, to: to) { items in
            let served = Self.asAnOlderCarrierServes(items, received: received)
            return served.filter { last == nil || $0.id != last } + served.filter { last != nil && $0.id == last }
        }
    }
}
