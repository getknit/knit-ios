import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// The group form's pure receive rules (ADR 2026-10.5sk9, phase P6a2): which refusal is which drop, which ask for a key,
/// which seeds wait for a roster and which a roster admits, which roster a seed may pin, and what a request and an ack are
/// sealed toward (`InboundPipeline.kt:1440-1730`, at knit-next `cbf2a487`).
@Suite struct GroupRatchetInboundTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let bob = TestPeer(seed: 3)

    @Test func eachRefusalIsItsOwnDropAndOnlyAMissingSeedAsksForAKey() {
        let reasons = [GroupRatchetEngine.OpenOutcome.Failed.noKey, .duplicate, .badHeader, .aeadFail].map(GroupRatchetInbound.dropReason)
        #expect(reasons == [.groupRatchetNoKey, .groupRatchetDuplicate, .groupRatchetBadHeader, .groupRatchetAeadFail])
        #expect(GroupRatchetInbound.asksForKey(.noKey) && GroupRatchetInbound.asksForKey(.aeadFail))
        #expect(!GroupRatchetInbound.asksForKey(.duplicate) && !GroupRatchetInbound.asksForKey(.badHeader))
    }

    @Test func onlyAGroupKeyWithAPayloadMeetsTheRosterGate() {
        let payload = GroupKeyPayload(groupId: "g-1")
        #expect(GroupRatchetInbound.seeds(in: MessageContent(body: "", ctl: MessageContent.Control.groupKey, gk: payload)) == payload)
        #expect(GroupRatchetInbound.seeds(in: MessageContent(body: "", ctl: MessageContent.Control.groupKeyAck, gk: payload)) == nil)
        #expect(GroupRatchetInbound.seeds(in: MessageContent(body: "", ctl: MessageContent.Control.groupKey)) == nil)
    }

    @Test func aSeedWaitsForNoRowOrADepartedSenderAndARosterAdmitsOnlyAPresentMember() throws {
        let info = roster([me, alice, bob], createdBy: alice)
        let held = GroupRecord(id: info.id, createdBy: info.createdBy, createdAt: 1, roster: info.members.map { GroupMember(nodeId: $0) })
        let gone = try #require(GroupRoster.depart(bob.nodeId, at: 5, from: held)).group
        var left = held
        left.hasLeft = true
        #expect(GroupRatchetInbound.awaitsRoster(nil, from: alice.nodeId) && GroupRatchetInbound.awaitsRoster(gone, from: bob.nodeId))
        #expect(!GroupRatchetInbound.awaitsRoster(held, from: alice.nodeId) && !GroupRatchetInbound.awaitsRoster(left, from: alice.nodeId))
        #expect(GroupRatchetInbound.admitsSeeds(of: alice.nodeId, in: held))
        #expect(!GroupRatchetInbound.admitsSeeds(of: alice.nodeId, in: nil) && !GroupRatchetInbound.admitsSeeds(of: alice.nodeId, in: left))
        #expect(
            !GroupRatchetInbound.admitsSeeds(of: bob.nodeId, in: gone)
                && !GroupRatchetInbound.admitsSeeds(of: TestPeer(seed: 9).nodeId, in: held))
    }

    @Test func aSeedPinsOnlyARosterOfItsOwnGroupWithinTheCap() {
        let info = roster([me, alice], createdBy: alice)
        #expect(GroupRatchetInbound.roster(pinnedBy: GroupKeyPayload(groupId: info.id, group: info)) == info)
        #expect(GroupRatchetInbound.roster(pinnedBy: GroupKeyPayload(groupId: info.id)) == nil, "an older build's seed")
        #expect(GroupRatchetInbound.roster(pinnedBy: GroupKeyPayload(groupId: "g-other", group: info)) == nil)
        var crowded = info
        crowded.members = (0...GroupInfo.maxMembers).map { "m\($0)" }
        #expect(GroupRatchetInbound.roster(pinnedBy: GroupKeyPayload(groupId: info.id, group: crowded)) == nil, "over the cap")
    }

    @Test func aRequestNeedsTheRatchetsBitAndAnAckOnlyABundleAndBothAreV2() throws {
        let android = try AndroidPeer(alice)
        let capable = PeerRecord(
            nodeId: alice.nodeId,
            name: "",
            status: "",
            publicKey: alice.keys.bundle.encoded,
            capabilities: AndroidPeer.capabilities,
            updatedAt: 1,
            prekey: android.prekey.info
        )
        var plain = capable
        plain.capabilities = 0xF
        let request = try #require(GroupRatchetInbound.keyRequestPlan(to: capable))
        #expect(request.prekey != nil && !request.readsCryptoV3, "its prekey where no session is held, and v2")
        #expect(GroupRatchetInbound.keyRequestPlan(to: plain) == nil && GroupRatchetInbound.keyRequestPlan(to: nil) == nil)
        let ack = try #require(GroupRatchetInbound.seedAckPlan(to: plain), "no bit asked for")
        #expect(ack.prekey == nil && !ack.readsCryptoV3 && ack.bundle == alice.keys.bundle)
        #expect(GroupRatchetInbound.seedAckPlan(to: nil) == nil)
    }
}
