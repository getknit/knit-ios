import KnitWire

@testable import KnitMesh

extension BlobExchange {
    /// One step of `hash`'s fetch with room in the echo budget, as a pure test that weighs no budget steps it.
    mutating func decide(_ hash: BlobHash, among linked: [Candidate], now: Int64, wall: Int64) -> Plan {
        decide(hash, among: linked, now: now, wall: wall, echoRoom: true)
    }
}
