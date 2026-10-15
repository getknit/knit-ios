import Foundation
import KnitWire
import Testing

@testable import KnitCrypto

/// The DM ratchet under the mesh's delivery pathology, two sides and a seeded run each (knit-next's `RatchetSoakTest`):
/// loss (custody eviction), reordering, duplication (re-serves), late replay, forced epoch churn, mixed v2 and v3, a
/// both-initiate race on some seeds, and one re-root by a reset mid-run while the old era keeps being re-served. Kotlin's
/// `Random` sequence does not reproduce here, so the seeds are this port's, drawn through ``SeededGenerator``.
///
/// Per seed: a frame sealed under the root its recipient holds as active opens on its first delivery, whatever an
/// earlier era left stored under its numbers, to exactly what was sealed; a re-delivery never yields a wrong plaintext;
/// skipped keys stay under one epoch's cap; two confirmed sides share one root; and the reset put a new-era frame on a
/// number an old era holds a chain for at least once, the #135 shape, or the run tested nothing of it.
@Suite struct RatchetSoakTests {
    static let seeds: [UInt64] = [1, 7, 42, 1337, 99_991]

    @Test(arguments: seeds) func theRatchetSurvivesLossReorderingDuplicationRacesAndAReset(seed: UInt64) throws {
        var run = try SoakRun(seed: seed)
        try run.run()

        #expect(run.opened > SoakRun.messages / 4, "seed \(seed): too little opened, the harness is broken")
        for side in [run.alice, run.bob] {
            #expect(side.rows.skippedKeys.count <= RatchetEngine.maxEpochMessages, "seed \(seed): skipped keys past one epoch's cap")
        }
        // Convergence holds once both sides confirmed: a total loss one way can leave a race unresolved, and the mesh's
        // answer to that is more re-serves, not a protocol guarantee.
        if let aliceSession = run.alice.session, let bobSession = run.bob.session, aliceSession.confirmed, bobSession.confirmed {
            #expect(aliceSession.root == bobSession.root, "seed \(seed): both sides confirmed on different roots")
        }
        #expect(run.collisions > 0, "seed \(seed): no new-era frame met an old era's chain of its number")
    }
}

/// One seeded run (`runSoak`, `RatchetSoakTest.kt:146-256`).
private struct SoakRun {
    static let messages = 400

    /// A frame and what the test knows about it (`Frame`, `RatchetSoakTest.kt:28-39`).
    struct Sent {
        let id: Int
        let frame: RatchetFrame
        let expected: String
        /// The sender's root when it sealed this frame.
        let root: [UInt8]
        /// A reset request, read with `FLAG_RESET` as `RatchetSessions.contextFor` reads one.
        let reset: Bool
    }

    let seed: UInt64
    let alice: RatchetSide
    let bob: RatchetSide
    private var random: SeededGenerator
    private var now = RatchetEngineTests.now
    private var inFlight: [(recipient: RatchetSide, sent: Sent)] = []
    /// Delivered or dropped: what custody re-serves.
    private var graveyard: [(recipient: RatchetSide, sent: Sent)] = []
    private var delivered: [ObjectIdentifier: Set<Int>] = [:]
    private(set) var opened = 0
    private(set) var collisions = 0

    init(seed: UInt64) throws {
        self.seed = seed
        random = SeededGenerator(seed: seed)
        (alice, bob) = try RatchetSide.pair()
    }

    mutating func run() throws {
        // Some seeds start with a both-initiate race.
        if Bool.random(using: &random) {
            try alice.initiate(now: now)
            try bob.initiate(now: now)
        }
        // One side re-roots once, somewhere in the middle third.
        let resetStep = Int.random(in: Self.messages / 3..<2 * Self.messages / 3, using: &random)
        let resetter = Bool.random(using: &random) ? alice : bob
        for step in 0..<Self.messages {
            now += Int64.random(in: 1..<60_000, using: &random)
            let sender = step == resetStep ? resetter : (Bool.random(using: &random) ? alice : bob)
            let sent = step == resetStep ? try reset(sender, id: step) : try seal(sender, id: step)
            inFlight.append((sender.other, sent))
            try shuffle()
            if !graveyard.isEmpty, Int.random(in: 0..<5, using: &random) == 0 {
                // A custody re-serve: an old frame, delivered or lost, comes back verbatim.
                let (recipient, replay) = graveyard[Int.random(in: 0..<graveyard.count, using: &random)]
                try deliver(replay, to: recipient)
            }
        }
        // The mesh eventually delivers what was not evicted.
        while !inFlight.isEmpty {
            let (recipient, sent) = inFlight.removeFirst()
            now += 1000
            try deliver(sent, to: recipient)
        }
    }

    /// A few in-flight frames delivered now, delayed or lost, in a shuffled order.
    private mutating func shuffle() throws {
        for _ in 0..<Int.random(in: 0..<4, using: &random) where !inFlight.isEmpty {
            let (recipient, candidate) = inFlight.remove(at: Int.random(in: 0..<inFlight.count, using: &random))
            switch Int.random(in: 0..<10, using: &random) {
            case 0...6: // delivered now
                if meetsAnotherErasChain(candidate, at: recipient) {
                    collisions += 1
                }
                try deliver(candidate, to: recipient)
                graveyard.append((recipient, candidate))
            case 7...8: // delayed: reordered
                inFlight.append((recipient, candidate))
            default: // lost to custody eviction, maybe re-served later
                graveyard.append((recipient, candidate))
            }
        }
    }

    /// Delivers a frame, asserting the one invariant that matters: a first open under the recipient's active root
    /// yields the right plaintext (`deliverAsserting`, `RatchetSoakTest.kt:269-293`).
    private mutating func deliver(_ sent: Sent, to recipient: RatchetSide) throws {
        let first = !(delivered[ObjectIdentifier(recipient)] ?? []).contains(sent.id)
        let underActiveRoot = recipient.session?.root == sent.root
        let outcome = try recipient.open(sent.frame, now: now, resetRequested: sent.reset)
        if first, underActiveRoot {
            #expect(outcome.opened != nil, "seed \(seed): frame \(sent.id), sealed under its recipient's root, gave \(outcome.vectorName)")
        }
        if let open = outcome.opened {
            #expect(String(bytes: open.plaintext, encoding: .utf8) == sent.expected, "seed \(seed): frame \(sent.id)")
            delivered[ObjectIdentifier(recipient), default: []].insert(sent.id)
            opened += 1
        }
    }

    private mutating func seal(_ sender: RatchetSide, id: Int) throws -> Sent {
        if sender.session == nil {
            try sender.initiate(now: now)
        }
        let force = Int.random(in: 0..<40, using: &random) == 0
        let v3 = Bool.random(using: &random)
        let body = "m\(id) from \(sender.nodeId)"
        let frame = try sender.seal(body, now: now, force: force, v3: v3)
        return Sent(id: id, frame: frame, expected: body, root: try #require(sender.session).root, reset: false)
    }

    /// A reset minted as `RatchetSessions.reRoot` mints one (``RatchetSide/reset(now:)``), whose plaintext is "reset".
    private func reset(_ sender: RatchetSide, id: Int) throws -> Sent {
        let frame = try sender.reset(now: now)
        return Sent(id: id, frame: frame, expected: "reset", root: try #require(sender.session).root, reset: true)
    }

    /// A first delivery of a frame sealed under its recipient's active root, onto a number another root holds a chain
    /// for (`meetsAnotherErasChain`, `RatchetSoakTest.kt:258-267`).
    private func meetsAnotherErasChain(_ sent: Sent, at recipient: RatchetSide) -> Bool {
        guard let root = recipient.session?.root, sent.root == root,
            !(delivered[ObjectIdentifier(recipient)] ?? []).contains(sent.id)
        else {
            return false
        }
        let tag = RatchetCrypto.rootTag(root)
        return recipient.rows.chains.keys.contains { key in key.epoch == sent.frame.header.se && key.rootTag != tag }
    }
}

/// SplitMix64, as `KnitMeshTests`' `SeededGenerator` (`EngineFixture.swift`): the test targets do not share it, so a run
/// here draws the same sequence every time from the same seed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
