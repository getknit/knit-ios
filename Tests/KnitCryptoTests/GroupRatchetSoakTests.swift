import Foundation
import KnitWire
import Testing

@testable import KnitCrypto

/// The group form under the mesh's delivery pathology, N members and a seeded run each (knit-next's
/// `GroupRatchetSoakTest`, at `cbf2a487`): loss (custody eviction), reordering, duplication (re-serves), late replay,
/// forced epoch churn, a departure mid-run and a wipe. The seeds travel a channel that loses nothing for good but
/// delays at will, standing in for the pairwise DM sessions, and a member that cannot read re-asks for the current
/// seeds, standing in for the key-request loop. Kotlin's `Random` sequence does not reproduce here, so the runs draw
/// through ``SeededGenerator`` on Kotlin's seeds, four members each and one run of eight, the roster cap.
///
/// One difference from Kotlin's soak, which still models a departure by deleting the remaining members' send chains, the
/// rule before knit-next `0f519d71`: here they retire them, as production does (knit-next ADR 2026-10.xgwj), so the next
/// mint numbers past the retired epoch. Both meet the invariants. The soak tests the engine alone: the send path's
/// distribution and outbox are P6b's, and the store's rows are ``GroupRatchetMember``'s.
///
/// Per seed: every frame that opens yields exactly what was sealed, however late and out of order; a re-process is a
/// duplicate or a banked key's hit, never a wrong plaintext; a member who left opens nothing sealed after the others
/// processed its departure; and the skipped keys stay bounded.
@Suite struct GroupRatchetSoakTests {
    static let seeds: [UInt64] = [1, 7, 42, 1337, 99_991, 4242]
    static let sizes = [4, 4, 4, 4, 4, 8]

    @Test(arguments: zip(seeds, sizes)) func theGroupRatchetSurvivesLossReorderingDeparturesAndWipes(seed: UInt64, members: Int) throws {
        var run = GroupSoakRun(seed: seed, members: members)
        try run.run()

        #expect(run.opened > GroupSoakRun.events / 4, "seed \(seed)/n=\(members): too little opened, the harness is broken")
        #expect(run.leaverViolations == 0, "seed \(seed)/n=\(members): a leaver opened traffic sealed after its departure")
        for member in run.members {
            let held = member.skipped.values.reduce(0) { $0 + $1.count }
            #expect(held <= GroupRatchetEngine.maxEpochMessages * members * 4, "seed \(seed)/n=\(members): skipped keys unbounded")
        }
    }
}

/// One seeded run (`runSoak`, `GroupRatchetSoakTest.kt:135-273`).
private struct GroupSoakRun {
    static let events = 400

    /// A sealed frame and what the test knows of it (`Frame`, `GroupRatchetSoakTest.kt:29-38`).
    struct Sent {
        let serial: Int
        let frame: GroupRatchetMember.Frame
        let expected: String
        /// The members whose departure the sender had processed when it sealed: they must never open it.
        let sealedAfterDeparture: Set<NodeId>
    }

    /// One seed offered to one recipient (`GroupSeedOffer`, `:119-125`).
    struct Offer {
        let sender: NodeId
        let chain: GroupRatchetEngine.SendChain
    }

    let members: [GroupRatchetMember]
    private var random: SeededGenerator
    private var now: Int64 = 1_700_000_000_000
    private var active: [GroupRatchetMember]
    private var departed: Set<NodeId> = []
    /// The members each sender's current epoch was offered to (`distributedTo`, `:48-49`).
    private var distributedTo: [NodeId: Set<NodeId>] = [:]
    private var seedChannel: [(recipient: GroupRatchetMember, offer: Offer)] = []
    private var inFlight: [(recipient: GroupRatchetMember, sent: Sent)] = []
    private var graveyard: [(recipient: GroupRatchetMember, sent: Sent)] = []
    private var serial = 0
    private(set) var opened = 0
    private(set) var leaverViolations = 0

    init(seed: UInt64, members count: Int) {
        members = (0..<count).map { GroupRatchetMember(100 + $0) }
        active = members
        random = SeededGenerator(seed: seed)
    }

    mutating func run() throws {
        for step in 0..<Self.events {
            now += Int64.random(in: 1..<60_000, using: &random)
            churnMembership(at: step)
            try sealOne()
            deliverSeeds()
            deliverFrames()
            reaskForSeeds()
            if !graveyard.isEmpty, Int.random(in: 0..<5, using: &random) == 0 {
                let (recipient, replay) = graveyard[Int.random(in: 0..<graveyard.count, using: &random)]
                deliver(replay, to: recipient)
            }
            // Forced churn: the clock jumps past the epoch's age cap now and then.
            if Int.random(in: 0..<60, using: &random) == 0 {
                now += GroupRatchetEngine.maxEpochAgeMilliseconds + 1
            }
        }
        // The mesh eventually delivers what was not evicted: every pending seed, then every pending frame.
        for (recipient, offer) in seedChannel {
            adopt(offer, by: recipient)
        }
        for (recipient, sent) in inFlight {
            now += 1000
            deliver(sent, to: recipient)
        }
    }

    /// A departure about mid-run, once, and a wipe after it on some seeds (`:158-171`). The remaining members retire their
    /// chains, so the next seal mints a fresh epoch offered to them alone.
    private mutating func churnMembership(at step: Int) {
        if departed.isEmpty, step == Self.events / 2, active.count > 2 {
            let leaver = active.remove(at: Int.random(in: 0..<active.count, using: &random))
            departed.insert(leaver.nodeId)
            for member in active {
                member.retire()
            }
        }
        if step == Self.events * 3 / 4, Bool.random(using: &random) {
            let wiped = active[Int.random(in: 0..<active.count, using: &random)]
            wiped.wipe()
            distributedTo[wiped.nodeId] = []
        }
    }

    /// A random active member seals, minting and offering its seed first when one is due (`:173-183`). The flood reaches
    /// every member still holding the group, the leaver included: frames are public custody, and the seed's secrecy is
    /// what keeps them closed.
    private mutating func sealOne() throws {
        let sender = active[Int.random(in: 0..<active.count, using: &random)]
        let others = active.filter { $0 !== sender }
        if GroupRatchetEngine.needsNewEpoch(sender.send, now: now) {
            let chain = sender.mint(now: now)
            distributedTo[sender.nodeId] = Set(others.map(\.nodeId))
            seedChannel += others.map { (recipient: $0, offer: Offer(sender: sender.nodeId, chain: chain)) }
        }
        let body = "m\(serial) from \(sender.nodeId)"
        let frame = try sender.seal("f\(serial)", body, now: now)
        let sent = Sent(serial: serial, frame: frame, expected: body, sealedAfterDeparture: departed)
        serial += 1
        inFlight += members.filter { $0 !== sender }.map { (recipient: $0, sent: sent) }
    }

    /// Lossy but eventually delivering, the DM layer's contract (`:185-195`): a seed is adopted, or put back for later.
    private mutating func deliverSeeds() {
        for _ in 0..<Int.random(in: 0..<3, using: &random) where !seedChannel.isEmpty {
            let entry = seedChannel.remove(at: Int.random(in: 0..<seedChannel.count, using: &random))
            if Int.random(in: 0..<10, using: &random) < 8 {
                adopt(entry.offer, by: entry.recipient)
            } else {
                seedChannel.append(entry)
            }
        }
    }

    /// Loss, reordering and duplication (`:197-223`): a frame is delivered, put back for later, or lost to custody's
    /// eviction, and may be re-served later from the graveyard.
    private mutating func deliverFrames() {
        for _ in 0..<Int.random(in: 0..<5, using: &random) where !inFlight.isEmpty {
            let entry = inFlight.remove(at: Int.random(in: 0..<inFlight.count, using: &random))
            switch Int.random(in: 0..<10, using: &random) {
            case 0...6:
                deliver(entry.sent, to: entry.recipient)
                graveyard.append(entry)
            case 7...8:
                inFlight.append(entry)
            default:
                graveyard.append(entry)
            }
        }
    }

    /// The key-request loop, modelled (`:225-236`): a member re-asks, and every other active member re-offers its current
    /// seed to it, if it was offered that epoch, and never to the departed.
    private mutating func reaskForSeeds() {
        guard Int.random(in: 0..<8, using: &random) == 0 else {
            return
        }
        let requester = active[Int.random(in: 0..<active.count, using: &random)]
        for responder in active where responder !== requester {
            guard let chain = responder.send, !chain.isRetired, distributedTo[responder.nodeId]?.contains(requester.nodeId) == true else {
                continue
            }
            seedChannel.append((recipient: requester, offer: Offer(sender: responder.nodeId, chain: chain)))
        }
    }

    private func adopt(_ offer: Offer, by recipient: GroupRatchetMember) {
        recipient.adopt(sender: offer.sender, epoch: offer.chain.epoch, seed: offer.chain.seed, mintedAt: offer.chain.mintedAt, now: now)
    }

    /// Delivers `sent` to `recipient`, checking what matters: an open yields the sealed plaintext, and a departed member
    /// never opens what was sealed after its departure (`deliverAsserting`, `:275-294`).
    private mutating func deliver(_ sent: Sent, to recipient: GroupRatchetMember) {
        guard case .opened(let result) = recipient.open(sent.frame, now: now) else {
            return
        }
        #expect(String(bytes: result.plaintext, encoding: .utf8) == sent.expected, "frame \(sent.serial) opened to the wrong plaintext")
        opened += 1
        // A second open of one frame comes only from a stored key a re-serve spent, and is never a wrong plaintext.
        if sent.sealedAfterDeparture.contains(recipient.nodeId) {
            leaverViolations += 1
        }
    }
}
