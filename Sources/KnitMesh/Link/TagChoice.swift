/// Which tag a blinding rotation airs (`TagChoice`, `AdvertWriter.kt:303-363` at knit-next `cad69c77b`; ADR 2026-11.prsp), as
/// one pure decision over the ``TagSchedule``: the key the link manager holds (`held`, the last
/// ``MeshTransport/ownPresenceKeyChanged(_:)`` handed in), the engine's value read just now (`live`,
/// ``PresenceKeySource/ownKey``), and whether the turn airs an announced slot (`announced`).
///
/// - No key: a random prefixed tag, never the id.
/// - The engine's generation is not the one held (a fresh pair the link manager has not yet taken in): a random tag, and the
///   reservation is dropped unaired; the key change follows and rotates again.
/// - Announced: exactly what ``TagSchedule/take(_:wall:)`` hands back; a reservation that missed its slot falls through.
/// - Otherwise ``TagSchedule/next(key:wall:marks:using:)``. A mark that will not read, or a write that is not durable (a
///   demoted generation's refused write, a store fault), gives a random tag: nothing airs under a mark that is not durable,
///   and never the id.
internal enum TagChoice {
    /// Why the tag is what it is: counted, never logged beside a time (`Source`, `:308`).
    enum Source: Hashable, CaseIterable {
        case announced
        case slotted
        case noKey
        case keyMoved
        case markFailed
    }

    /// A rotation's tag. `generation` is the key generation it aired under, `nil` with no key or one the engine moved past.
    struct Choice: Equatable, CustomStringConvertible {
        let form: AdvertOrder.Form
        let generation: Int64?
        let source: Source
        let resolvable: Bool
        let stale: Bool

        /// Never the tag.
        var description: String { "Choice(source: \(source), resolvable: \(resolvable))" }
    }

    /// The tag to air now (`choose`, `:321-343`).
    static func choose( // swiftlint:disable:this function_parameter_count - Kotlin's five, and the store and generator it injects
        _ schedule: inout TagSchedule,
        held: OwnPresenceKey?,
        live: OwnPresenceKey?,
        announced: Bool,
        wall: Int64,
        marks: some TagMarks,
        using generator: inout some RandomNumberGenerator
    ) -> Choice {
        guard let held else {
            return randomChoice(.noKey, generation: nil, using: &generator)
        }
        // A reservation is spent here whatever follows: aired if announced and on time, else passed by unaired.
        let taken = schedule.take(held.generation, wall: wall)
        guard live?.generation == held.generation else {
            return randomChoice(.keyMoved, generation: nil, using: &generator)
        }
        if announced, let taken {
            return slotted(taken, generation: held.generation, source: .announced)
        }
        do {
            let next = try schedule.next(key: held, wall: wall, marks: marks, using: &generator)
            return slotted(next, generation: held.generation, source: .slotted)
        } catch {
            return randomChoice(.markFailed, generation: held.generation, using: &generator)
        }
    }

    private static func slotted(_ next: TagSchedule.Next, generation: Int64, source: Source) -> Choice {
        Choice(
            form: AdvertOrder.Form(advertised: next.tag, blinded: true),
            generation: generation,
            source: source,
            resolvable: next.resolvable,
            stale: next.stale
        )
    }

    private static func randomChoice(_ source: Source, generation: Int64?, using generator: inout some RandomNumberGenerator) -> Choice {
        Choice(
            form: AdvertOrder.Form(advertised: TagSchedule.randomTag(using: &generator).tag, blinded: true),
            generation: generation,
            source: source,
            resolvable: false,
            stale: false
        )
    }
}
