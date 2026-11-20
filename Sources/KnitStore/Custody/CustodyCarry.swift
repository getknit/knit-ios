/// What a custody write reads of this node's own view of the mesh: how many peers are believed to hold each frame (the
/// `custody-carry-policy` contract, §3 and §5). KnitStore cannot see the engine that keeps the ledger, so the engine hands
/// one of these to ``CustodyStore/store(_:origin:now:carry:)``.
///
/// Only the global cap's choice of row reads it (``CustodyRules/evictions(after:among:limits:carry:)``), and only while the
/// cap binds: admission, the TTLs, the sender, group and room trims and the digest never do. Below the cap two stores
/// holding the same frames keep the same ones whatever it says. At the cap the stores of two nodes may differ for good,
/// which the contract accepts (§9).
public protocol CustodyCarry {
    /// How many distinct peers are believed to hold `id`, ourselves and the router's live relay not counted. The rule caps
    /// it at ``CustodyLimits/spreadMax``, so an answer past that ties with it. The id compares by its bytes.
    func holders(of id: String) -> Int
}

/// The carry that knows of no holder: every spread is 0, and the global cap's choice is the old `(count, sentAt, id)` rule
/// (contract §5, "With no holders recorded, the order is today's").
public struct NoCustodyCarry: CustodyCarry, Sendable {
    /// The empty carry.
    public init() {
        // Nothing known.
    }

    /// No peer known to hold anything.
    public func holders(of _: String) -> Int {
        0
    }
}
