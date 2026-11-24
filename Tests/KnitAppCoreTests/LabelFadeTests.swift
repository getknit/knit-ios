import KnitAppCore
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// When a stranger's name clash fades, ported from knit-next's `LabelFadeTest` and `LabelAnchorsTest` (ADR 2026-10.k8ge
/// there): a week of silence, judged strictly, and never for an anchored or verified peer.
@Suite struct LabelFadeTests {
    private let now: Int64 = 1_800_000_000_000
    private let stranger = fixtureNodeId(1)
    private let contact = fixtureNodeId(2)

    @Test func aStrangerSilentForExactlyAWeekStillClashes() {
        #expect(
            !LabelFade.fades(
                nodeId: stranger, verified: false, lastSeenAt: now - LabelFade.windowMilliseconds, anchors: [], now: now))
    }

    @Test func aStrangerSilentForAWeekAndAMillisecondFades() {
        #expect(
            LabelFade.fades(
                nodeId: stranger, verified: false, lastSeenAt: now - LabelFade.windowMilliseconds - 1, anchors: [], now: now))
    }

    @Test func anAnchoredPeerNeverFadesHoweverLongItIsSilent() {
        #expect(!LabelFade.fades(nodeId: contact, verified: false, lastSeenAt: 0, anchors: [contact], now: now))
    }

    @Test func aVerifiedPeerNeverFadesHoweverLongItIsSilent() {
        #expect(!LabelFade.fades(nodeId: contact, verified: true, lastSeenAt: 0, anchors: [], now: now))
    }

    /// A peer row for `nodeId`, last heard at `heard`.
    private func peer(_ nodeId: NodeId, heard: Int64, verified: Bool = false) -> PeerRecord {
        PeerRecord(nodeId: nodeId, name: "Alice", status: "", publicKey: "", updatedAt: 1, verified: verified, lastSeenAt: heard)
    }

    @Test func theAnchorsAreReadOnlyWhenSomeoneWentQuiet() {
        var reads = 0
        func anchors(_ held: Set<NodeId>) -> Set<NodeId> {
            reads += 1
            return held
        }
        let heard = [peer(stranger, heard: now)]
        #expect(LabelFade.stale(among: heard, now: now) { anchors([]) }.isEmpty)
        #expect(reads == 0, "nobody is quiet, so the messages are never looked through")

        let quiet = [peer(stranger, heard: 0), peer(contact, heard: 0), peer(fixtureNodeId(3), heard: 0, verified: true)]
        #expect(LabelFade.stale(among: quiet, now: now) { anchors([contact]) } == [stranger])
        #expect(reads == 1)
    }

    @Test func anAnchorsReadThatFailedFadesNobody() {
        let quiet = [peer(stranger, heard: 0)]
        #expect(LabelFade.stale(among: quiet, now: now) { nil }.isEmpty, "an unreadable anchor set keeps every clash")
    }

    // MARK: Anchors

    @Test func aDmWeAcceptedOrWroteInAnchorsItsPeer() {
        let accepted = fixtureNodeId(4)
        let authored = fixtureNodeId(5)
        let anchors = LabelAnchors.of(accepted: [accepted.string], authored: [authored.string], groups: [])
        #expect(anchors == [accepted, authored])
    }

    @Test func groupAndRoomIdsAreNotAnchorsAndALeftGroupLendsNobody() {
        let member = fixtureNodeId(6)
        let gone = fixtureNodeId(7)
        let leftBehind = fixtureNodeId(8)
        let kept = GroupRecord(
            id: "g-kept",
            createdBy: member.string,
            createdAt: 1,
            roster: [GroupMember(nodeId: member.string), GroupMember(nodeId: gone.string, departed: true)]
        )
        let left = GroupRecord(
            id: "g-left", createdBy: leftBehind.string, createdAt: 1, hasLeft: true, roster: [GroupMember(nodeId: leftBehind.string)])
        let anchors = LabelAnchors.of(
            accepted: [Conversations.nearby, "g-kept", "g-left"], authored: [Conversations.nearby, "g-kept"], groups: [kept, left])
        #expect(anchors == [member], "a member who left lends nothing, and neither does a group we left")
    }

    /// Every peer a thread counts as accepted (``Conversations/isAccepted(_:accepted:verified:authored:groupSenders:)``)
    /// is an anchor once the caller adds the verified: the anchors are wider than the contact rule on purpose.
    @Test func everyContactIsAnAnchor() {
        let pool = (0..<12).map { fixtureNodeId(100 + $0) }
        var draw: UInt64 = 0x2545_F491_4F6C_DD1D
        func coin() -> Bool {
            draw ^= draw << 13
            draw ^= draw >> 7
            draw ^= draw << 17
            return draw.isMultiple(of: 3)
        }
        for _ in 0..<500 {
            let accepted = Set(pool.filter { _ in coin() }.map(\.string))
            let authored = Set(pool.filter { _ in coin() }.map(\.string))
            let verified = Set(pool.filter { _ in coin() })
            let roster = pool.filter { _ in coin() }.map { GroupMember(nodeId: $0.string, departed: coin()) }
            let group = GroupRecord(id: "g-one", createdBy: pool[0].string, createdAt: 1, hasLeft: coin(), roster: roster)
            let anchors = LabelAnchors.of(accepted: accepted, authored: authored, groups: [group]).union(verified)
            for peer in pool
            where Conversations.isAccepted(peer.string, accepted: accepted, verified: verified, authored: authored) {
                #expect(anchors.contains(peer))
            }
        }
    }
}
