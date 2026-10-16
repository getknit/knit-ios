/// What one store unit came to (``StoreTransactor/atomically(_:)``).
///
/// Only the outermost unit's ``committed(_:)`` lets the work it carries run. A unit nested in another answers
/// ``joined(_:)`` instead, since its writes stand only if the outermost commits, and its caller hands that work up through
/// the outer body. A nested unit that answered ``committed(_:)`` would let a helper send on it, and if the outer unit then
/// failed, the send's chain would be undone and its message key used again.
public enum Transacted<Value> {
    /// The outermost unit committed: every write in it stands, and `Value` is the work its body left for after the commit,
    /// the sends, events and deliveries a unit never makes itself, which may run now.
    case committed(Value)
    /// A unit nested in another ended with its writes joined to that one, where they stand only if the outermost commits.
    /// `Value` is the work its body answered, which must not run here: the caller hands it up through the outer body's
    /// answer, and it runs once the outermost answers ``committed(_:)``.
    case joined(Value)
    /// The body answered `nil` and nothing in the unit failed: every write it made is undone. A nested unit undoes only its
    /// own.
    case abandoned
    /// A store failed inside the unit, or the database could not begin or commit it: every write in the outermost unit is
    /// undone, and the database reported the error once, as a store reports one. Every unit that sees the failure answers
    /// this, whatever its body answered, `nil` included. Nothing the body would have done may run.
    case failed
}

extension Transacted: Sendable where Value: Sendable {}

extension Transacted: Equatable where Value: Equatable {}

/// The store unit the ratchet commits in (ADR 2026-10.5sk9): every store write inside it lands together or not at all,
/// and a store that fails inside it fails the whole unit, which then closes rather than opens.
///
/// A ratchet session that advances while the message row it carried is lost has spent that message's key for good, and
/// a send whose advanced chain was lost seals its next message under the same key. Outside a unit a store still answers
/// as if nothing were there when it fails (ADR 2026-09.nyya). Inside one, any store error fails the unit, a read's as
/// much as a write's, since its body may have decided on the fallback, except a blob's file error, which is reported and
/// fails nothing. A blob's file is no part of the transaction, and failing a DM's unit on an unreadable photo would leave
/// the DM undelivered and fail it again at every re-serve. So a `nil` or `false` from a blob's bytes inside a unit may
/// only mean doing nothing (as `notePlainHash` does), never a decision. Android's equivalent is `SessionTransactor` with
/// Room's reentrant transaction, taken before the ratchet's mutex (`SessionTransactor.kt:30-43` and `MeshModule.kt:222-227`,
/// knit-next `ac491f4c`). The engine here is one synchronous actor (ADR 2026-09.gq84), so it takes no mutex, and the unit
/// alone is outermost.
///
/// The body's contract, which the engine keeps and the crypto reviewer's shape 18 checks:
/// - It reads and writes stores and nothing else. It never sends, emits an event, touches the Keychain or changes policy
///   kept in memory, and it leaves writing or removing a blob to the work after the commit, since a blob's file is no
///   part of the transaction (``BlobStore``). The one write in memory a unit may make is the tombstone `CustodySync.admits`
///   sets for a DM whose recipient's receipt came first: idempotent, and the verdict a later `carry` reaches anyway, so
///   the ratchet's send unit keeps our custody's copy inside it.
/// - It answers the work for after the commit as a value, or `nil` to abandon the unit. That work runs only once the
///   outermost unit answers ``Transacted/committed(_:)``. A unit nested in another answers ``Transacted/joined(_:)``,
///   and its caller hands the work up through its own body's answer. After ``Transacted/failed`` nothing is delivered
///   or sent.
/// - It stays short: on the database, a unit holds the writer from its first statement to its commit.
public protocol StoreTransactor: AnyObject, Sendable {
    /// Runs `body` as one unit: every store write in it commits together, or none does. A unit opened inside another
    /// joins it and answers ``Transacted/joined(_:)``, a failure anywhere in it fails the outermost, and a unit opened
    /// inside one that has already failed answers ``Transacted/failed`` without running its body.
    func atomically<Value>(_ body: () -> Value?) -> Transacted<Value>
}
