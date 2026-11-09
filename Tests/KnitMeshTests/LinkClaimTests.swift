import KnitCrypto
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Who must prove the id a HELLO claims, and what a proof displaces (the `link-hello-proof` contract, §7: R1 to R4;
/// knit-ios #25).
@Suite struct LinkClaimTests {
    private let low = LinkRig.low
    private let middle = LinkRig.middle
    private let high = LinkRig.high
    private let proving = Neighbor(nodeId: LinkRig.low, protocolVersion: 1, capabilities: LinkRig.provingCapabilities)
    private let legacy = Neighbor(nodeId: LinkRig.low, protocolVersion: 1, capabilities: 0xFFF)

    private func counts(_ rig: LinkRig) -> [Int] {
        [rig.links.linksProven, rig.links.linkProofFailed, rig.links.linkClaimRefused]
    }

    /// `low` dials us and proves itself on `id`.
    private func provenLink(_ rig: LinkRig, on id: ChannelID) throws -> [LinkManager.Event] {
        let (hello, _) = rig.acceptProving(low, on: id)
        return try rig.proveDialer(low, on: id, hello: hello)
    }

    // MARK: R1

    @Test func anUnprovenDialerClaimingAnIdWhoseProfileProvesIsRefusedUnanswered() {
        let rig = LinkRig(local: high)
        rig.proofProfiles.ids.insert(low)
        #expect(rig.accept(low, on: ChannelID(100)).isEmpty)
        #expect(rig.radio.closed == [ChannelID(100)])
        #expect(rig.radio.records(on: ChannelID(100)).isEmpty, "refused before any reply")
        #expect(counts(rig) == [0, 0, 1])
        #expect(rig.said("link refused \(low): an unproven claim to a node that proves itself"))
        #expect(rig.radio.hellos.map(\.node) == [low], "its HELLO was heard all the same")
    }

    @Test func anIdProvenThisRunMustProveItselfAgain() throws {
        let rig = LinkRig(local: high)
        _ = try provenLink(rig, on: ChannelID(100))
        _ = rig.handle(.closed(ChannelID(100)))
        #expect(rig.accept(low, on: ChannelID(101)).isEmpty)
        #expect(counts(rig) == [1, 0, 1])
    }

    /// R1 runs before today's refusals, so the claim is counted even where "already linked" would refuse it too.
    @Test func r1ComesBeforeTheRefusalsOfToday() throws {
        let rig = LinkRig(local: high)
        _ = try provenLink(rig, on: ChannelID(100))
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        #expect(rig.accept(low, on: ChannelID(101)).isEmpty)
        #expect(rig.radio.closed == [ChannelID(101)])
        #expect(counts(rig) == [1, 0, 1])
        #expect(!rig.said("link refused \(low): already linked"))
        #expect(rig.links.neighbors.map(\.nodeId) == [low], "the real link stays")
    }

    /// A live proven link is a proof this run on its own, so its id stays proof-capable after the bounded set forgets it.
    @Test func aLiveProvenLinkKeepsItsIdProofCapableOnceTheSetForgetsIt() throws {
        let rig = LinkRig(local: high)
        _ = try provenLink(rig, on: ChannelID(100))
        for index in 0..<LinkClaims.maxProven {
            rig.links.claims.proved(Self.node(index))
        }
        #expect(!rig.links.claims.isProofCapable(low), "the set has forgotten it, and no profile says it")
        #expect(rig.accept(low, on: ChannelID(101)).isEmpty)
        #expect(rig.radio.closed == [ChannelID(101)])
        #expect(rig.links.linkClaimRefused == 1, "refused and counted under R1")
        #expect(rig.said("link refused \(low): an unproven claim to a node that proves itself"))
        #expect(rig.links.neighbors.map(\.nodeId) == [low], "the real link stays")
    }

    @Test func aDialerRefusesAnUnprovenReplyFromAnIdThatProvesAndBacksOff() throws {
        let rig = LinkRig(local: high)
        rig.proofProfiles.ids.insert(low)
        let id = try rig.link(low)
        #expect(rig.links.neighbors.isEmpty)
        #expect(rig.radio.closed == [id])
        #expect(counts(rig) == [0, 0, 1])
        #expect(rig.radio.records(on: id).map(\.tag) == [.hello], "no proof written")
        rig.advance(8000, hearing: low)
        #expect(rig.radio.dials.count == 1, "backing off")
    }

    // MARK: R2

    @Test func aProvenLinkIsReplacedOnlyOnceTheNewLinkProvesItself() throws {
        let rig = LinkRig(local: high)
        _ = try provenLink(rig, on: ChannelID(100))
        _ = rig.advance(30_000)
        let (hello, admitted) = rig.acceptProving(low, on: ChannelID(101))
        #expect(admitted.isEmpty)
        #expect(rig.radio.closed.isEmpty, "the held link stays until the proof verifies")
        let events = try rig.proveDialer(low, on: ChannelID(101), hello: hello)
        #expect(events == [.down(low), .up(proving)])
        #expect(rig.radio.closed == [ChannelID(100)])
        #expect(rig.said("link \(low) replaced its stale link ch100 with ch101"))
        #expect(counts(rig) == [2, 0, 0])
    }

    @Test func aProvenLinkStaysWhenItsReplacementFailsItsProof() throws {
        let rig = LinkRig(local: high)
        _ = try provenLink(rig, on: ChannelID(100))
        _ = rig.advance(30_000)
        let (hello, _) = rig.acceptProving(low, on: ChannelID(101))
        #expect(try rig.proveDialer(low, on: ChannelID(101), hello: hello, keys: LinkRig.keys(of: middle)).isEmpty)
        #expect(rig.radio.closed == [ChannelID(101)])
        #expect(rig.links.neighbors.map(\.nodeId) == [low])
        #expect(counts(rig) == [1, 1, 0])
    }

    @Test func aYoungProvenLinkIsNotReplacedEvenByAProof() throws {
        let rig = LinkRig(local: high)
        _ = try provenLink(rig, on: ChannelID(100))
        _ = rig.advance(29_999)
        #expect(rig.acceptProving(low, on: ChannelID(101)).events.isEmpty)
        #expect(rig.radio.closed == [ChannelID(101)])
        #expect(rig.radio.records(on: ChannelID(101)).isEmpty)
        #expect(rig.said("link refused \(low): its link is too young to replace"))
    }

    // MARK: R3

    @Test func aProofDisplacesAnUnprovenLinkClaimingItsIdWhateverItsAgeOrSighting() throws {
        let rig = LinkRig(local: high)
        _ = rig.accept(low, on: ChannelID(100))
        // Now sighted, and below us: our rule says we dial it, which would refuse its dial, and the squatter is young.
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        let (hello, admitted) = rig.acceptProving(low, on: ChannelID(101))
        #expect(admitted.isEmpty)
        #expect(rig.radio.closed.isEmpty, "the squatter stays until the proof verifies")
        #expect(rig.links.neighbors.map(\.nodeId) == [low])
        let events = try rig.proveDialer(low, on: ChannelID(101), hello: hello)
        #expect(events == [.down(low), .up(proving)])
        #expect(rig.radio.closed == [ChannelID(100)])
        #expect(rig.said("link ch100 displaced: \(low) proved itself on ch101"))
        #expect(counts(rig) == [1, 0, 1])
        #expect(rig.handle(.closed(ChannelID(100))).isEmpty, "the squatter's close takes nothing down")
    }

    @Test func anUnprovenLinkStaysWhenTheProofFails() throws {
        let rig = LinkRig(local: high)
        _ = rig.accept(low, on: ChannelID(100))
        let (hello, _) = rig.acceptProving(low, on: ChannelID(101))
        #expect(try rig.proveDialer(low, on: ChannelID(101), hello: hello, keys: LinkRig.keys(of: middle)).isEmpty)
        #expect(rig.radio.closed == [ChannelID(101)])
        #expect(rig.links.neighbors == [legacy])
        #expect(counts(rig) == [0, 1, 0])
    }

    @Test func aDialerProvingAnIdDisplacesTheUnprovenLinkThatCameInMeanwhile() throws {
        // An iPhone below a phone that cannot find it dials up; meanwhile a dial claiming that phone, now flagged, lands.
        let rig = LinkRig(local: low, advertisesServiceData: false)
        rig.sightToPromotion(high, flags: 0)
        let id = try #require(rig.radio.dials.first?.channel)
        rig.clock.advance(1)
        _ = rig.handle(.sighted(LinkRig.sighting(high)))
        _ = rig.accept(high, on: ChannelID(100))
        _ = rig.handle(.connected(id))
        let events = try rig.answerProving(high, on: id).events
        #expect(
            events == [.down(high), .up(Neighbor(nodeId: high, protocolVersion: 1, capabilities: LinkRig.provingCapabilities))])
        #expect(rig.radio.closed == [ChannelID(100)])
        #expect(counts(rig) == [1, 0, 1])
    }

    // MARK: R4

    @Test func aProfileGainingTheBitClosesTheUnprovenLinkAtOnce() {
        let rig = LinkRig(local: high)
        _ = rig.accept(low, on: ChannelID(100))
        rig.proofProfiles.ids.insert(low)
        rig.links.peerProvesItself(low)
        #expect(rig.links.neighbors.isEmpty, "out of every send's targets before the engine sends on")
        #expect(rig.radio.closed == [ChannelID(100)])
        #expect(rig.links.nextDeadline == rig.clock.monotonicMilliseconds(), "its down is handed over at once")
        #expect(rig.links.advance() == [.down(low)])
        #expect(rig.links.advance().isEmpty, "once")
        #expect(counts(rig) == [0, 0, 1])
        #expect(rig.said("link ch100 closed: \(low) proves itself"))
    }

    @Test func aProvenLinkStaysWhenTheProfileGainsTheBit() throws {
        let rig = LinkRig(local: high)
        _ = try provenLink(rig, on: ChannelID(100))
        rig.links.peerProvesItself(low)
        #expect(rig.links.neighbors.map(\.nodeId) == [low])
        #expect(rig.links.advance().isEmpty)
        #expect(counts(rig) == [1, 0, 0])
    }

    /// The `.down` of a link the profile closed comes ahead of the `.up` of the proof that follows it, never after.
    @Test func aCloseForAProfileComesBeforeTheProofsUpInOneEntry() throws {
        let rig = LinkRig(local: high)
        _ = rig.accept(low, on: ChannelID(100))
        let (hello, _) = rig.acceptProving(low, on: ChannelID(101))
        rig.links.peerProvesItself(low)
        #expect(try rig.proveDialer(low, on: ChannelID(101), hello: hello) == [.down(low), .up(proving)])
        #expect(counts(rig) == [1, 0, 1])
    }

    // MARK: Who proves what

    @Test func theIdsProvenThisRunAreCappedLeastRecentFirst() {
        var claims = LinkClaims { _ in false }
        let ids = (0...LinkClaims.maxProven + 1).map(Self.node)
        for id in ids.dropLast() {
            claims.proved(id)
        }
        claims.proved(ids[0])
        claims.proved(Self.node(LinkClaims.maxProven + 1))
        #expect(claims.isProofCapable(ids[0]), "refreshed by its newest proof")
        #expect(!claims.isProofCapable(ids[1]) && !claims.isProofCapable(ids[2]), "the least recently proven went")
        #expect(claims.isProofCapable(ids[LinkClaims.maxProven]) && claims.isProofCapable(ids[LinkClaims.maxProven + 1]))
        #expect(claims.linksProven == LinkClaims.maxProven + 3)
    }

    /// A distinct node id for each index.
    private static func node(_ index: Int) -> NodeId {
        guard
            let id = NodeId(
                bytes: [UInt8(truncatingIfNeeded: index >> 8), UInt8(truncatingIfNeeded: index)] + [UInt8](repeating: 0, count: 14))
        else {
            fatalError("any 16 bytes are a node id")
        }
        return id
    }

    @Test func anIdWhoseStoredProfileCarriesTheBitIsProofCapable() {
        let claims = LinkClaims { $0 == LinkRig.middle }
        #expect(claims.isProofCapable(middle))
        #expect(!claims.isProofCapable(low))
        #expect(claims.linksProven == 0, "the profile makes it proof-capable, not a proof")
    }
}
