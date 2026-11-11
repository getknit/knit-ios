/// One search of every `0xFE30` service a peer serves, for the payload or the doorbell (ADR 2026-11.prsp): KnitBLE's
/// payload read and its doorbell lookup each keep one per peripheral.
///
/// A blinding iPhone serves two `0xFE30` primaries, the doorbell's and the payload's, and for a moment during a rotation
/// three. A reader that took the first `0xFE30` service, as KnitBLE did, finds the doorbell where it looks for the payload
/// and files a blinding iPhone as a stranger for ten minutes, or finds the payload where it looks for the doorbell and
/// never rings it. CoreBluetooth answers a characteristic discovery per service, so the search ends only once every service
/// asked about has answered: the first characteristic found wins, a failure counts only when nothing was found, and an
/// answer for a service this search did not ask about, or one it already heard, changes nothing. KnitBlueZ needs none:
/// `GetManagedObjects` lists every service at once (`BlueZ.knitCharacteristic`).
public struct GattSweep<Key: Hashable, Found> {
    /// How a search ended.
    public enum Outcome {
        /// A service held what was looked for: the first one found.
        case found(Found)
        /// No service held it. `failed` when a service's discovery failed, so the answer is not a peer's own.
        case missing(failed: Bool)
    }

    /// The services still to answer.
    public private(set) var pending: Set<Key>
    private var found: Found?
    private var failed = false

    /// A search of the services `keys`, which must not be empty: a peer with no `0xFE30` service ends its search before
    /// one starts.
    public init(_ keys: some Sequence<Key>) {
        pending = Set(keys)
    }

    /// Whether the search still waits on one of the services `invalidated`: a services change took it, and CoreBluetooth may
    /// never answer a discovery already asked of it, so the search starts again from a fresh list.
    public func waitsOnAny(of invalidated: some Sequence<Key>) -> Bool {
        !pending.isDisjoint(with: invalidated)
    }

    /// The service `key` answered, holding `found` or not, after its discovery `failed` or not. Answers how the search
    /// ended once this was the last service to answer, and `nil` while others still owe theirs, or for a service it was
    /// not waiting on.
    public mutating func answered(_ key: Key, found: Found?, failed: Bool) -> Outcome? {
        guard pending.remove(key) != nil else {
            return nil
        }
        if self.found == nil {
            self.found = found
        }
        self.failed = self.failed || failed
        guard pending.isEmpty else {
            return nil
        }
        return self.found.map(Outcome.found) ?? .missing(failed: self.failed)
    }
}

extension GattSweep: Sendable where Key: Sendable, Found: Sendable {}

extension GattSweep.Outcome: Sendable where Found: Sendable {}

extension GattSweep.Outcome: Equatable where Found: Equatable {}
