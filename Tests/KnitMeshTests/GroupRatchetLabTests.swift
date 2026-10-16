import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The receive side of knit-next's group labs, as engines on links (ADR 2026-10.5sk9, phase P6a2): `GroupFirstMessageLabTest`,
/// `SessionLabTest.aMemberWhoMissedTheSeedAsksAfterThreeUnreadableFrames` and `GroupMembershipLabTest`'s overtaking seeds (at
/// knit-next `cbf2a487`). Nothing here seals the group form before P6b, so an Android phone authors it (``GroupFormAuthor``)
/// and hands its frames to the node it is linked to; the iPhones receive, relay and carry them.
@Suite struct GroupRatchetLabTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)

    private var now: Int64 { EngineFixture.start }
    private var jitter: Int64 { Router.Configuration().jitterWindowMilliseconds + 1 }

    /// Node 0, the iPhone with the switch on, linked to node 1, a carrier, both with Alice pinned.
    private func carried(stores: MeshStores = .inMemory(), keychain: KeptSecretStore? = nil, holding: Bool = false) throws -> (
        EngineLab, AndroidPeer
    ) {
        let android = try AndroidPeer(alice)
        let iphone = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain)
        let carrier = EngineFixture(carol, seed: 9)
        try iphone.pin(android)
        try carrier.pin(android)
        let lab = EngineLab([iphone, carrier])
        lab.link(0, 1, holding: holding ? [(from: 1, to: 0)] : [])
        lab.advance(jitter)
        return (lab, android)
    }

    /// Alice's frame handed to node `index`, and relayed on once the router's jitter runs out.
    private func arrive(_ frame: TestFrame, at index: Int, in lab: EngineLab) {
        lab[index].deliver(frame, from: alice)
        lab.advance(jitter)
    }

    private func isGroupFrame(_ item: EngineLab.Carried) -> Bool {
        guard case .frame(let written) = item else {
            return false
        }
        return written.envelope.group != nil
    }

    @Test func firstGroupMessageLandsWhenTheSeedOutrunsTheRoster() throws {
        let (lab, android) = try carried()
        let group = roster([me, alice], createdBy: alice)
        let author = GroupFormAuthor(android, in: group.id)
        arrive(try author.seedDm(to: me, prekey: try lab[0].ourPrekey(), id: "seed-1", sentAt: now), at: 1, in: lab)
        arrive(try author.frame(group, id: "g-welcome", body: "welcome", sentAt: now + 1), at: 1, in: lab)
        #expect(lab[0].stores.messages.message("g-welcome")?.body == "welcome")
        #expect(lab[0].engine.dropped[.groupRatchetNoKey] == nil && lab[0].engine.dropped[.ratchetDuplicate] == nil)
        #expect(lab[0].engine.groupCounts.groupSeedsHeld == 1 && lab[0].engine.groupCounts.groupSeedsReplayed == 1)
        lab.advance(MeshConfiguration().reofferMilliseconds)
        #expect(Set(lab.liveIds(0)) == Set(lab.liveIds(1)))
    }

    @Test func firstGroupMessageLandsWhenTheMemberRestartsBetweenTheSeedAndTheFrame() throws {
        let stores = MeshStores.inMemory()
        let keychain = KeptSecretStore(me.keys.storedForm)
        let (lab, android) = try carried(stores: stores, keychain: keychain, holding: true)
        let group = roster([me, alice], createdBy: alice)
        let author = GroupFormAuthor(android, in: group.id)
        arrive(try author.seedDm(to: me, prekey: try lab[0].ourPrekey(), id: "seed-1", sentAt: now, roster: group), at: 1, in: lab)
        arrive(try author.frame(group, id: "g-welcome", body: "welcome", sentAt: now + 1), at: 1, in: lab)
        // Only the DMs, the seed among them, through: the group frame stays on the link.
        lab.release(from: 1, to: 0) { $0.filter { !isGroupFrame($0) } }
        #expect(lab[0].stores.groups.group(group.id) != nil, "pinned from the seed")
        #expect(lab[0].recvChains(group.id, from: alice).count == 1 && lab[0].engine.groupCounts.groupSeedsHeld == 0)
        lab.replace(0, with: try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: now + 60_000, seed: 8))
        lab[1].clock.advance(60_000)
        lab.link(0, 1)
        #expect(lab[0].stores.messages.message("g-welcome")?.body == "welcome", "back-filled, and opened on its first pass")
        #expect(lab[0].engine.dropped[.groupRatchetNoKey] == nil)
    }

    @Test func firstGroupMessageLandsAcrossARelay() throws {
        let android = try AndroidPeer(alice)
        let first = try EngineFixture.ratcheting(me, seed: 11)
        let second = try EngineFixture.ratcheting(dave, seed: 12)
        try first.pin(android)
        try second.pin(android)
        let lab = EngineLab([first, second])
        lab.link(0, 1)
        lab.advance(jitter)
        let group = roster([alice, me, dave], createdBy: alice)
        let author = GroupFormAuthor(android, in: group.id)
        // Alice reaches only the first iPhone; the second hears her seed and her frame through its relay.
        arrive(try author.seedDm(to: me, prekey: try lab[0].ourPrekey(), id: "seed-me", sentAt: now), at: 0, in: lab)
        arrive(try author.seedDm(to: dave, prekey: try lab[1].ourPrekey(), id: "seed-dave", sentAt: now), at: 0, in: lab)
        arrive(try author.frame(group, id: "g-all", body: "all three", sentAt: now + 1), at: 0, in: lab)
        #expect(lab[0].stores.messages.message("g-all")?.body == "all three")
        #expect(lab[1].stores.messages.message("g-all")?.body == "all three", "across the relay")
        lab.advance(MeshConfiguration().reofferMilliseconds)
        #expect(Set(lab.liveIds(0)) == Set(lab.liveIds(1)))
    }

    @Test func aMemberWhoMissedTheSeedAsksAfterThreeUnreadableFrames() throws {
        let fixture = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        let group = fixture.holdGroup(with: [alice])
        let author = GroupFormAuthor(android, in: group.id)
        for index in 1...3 {
            fixture.deliver(
                try author.frame(group, id: "sealed-\(index)", body: "sealed \(index)", sentAt: now + Int64(index)), from: alice)
        }
        let requests = fixture.controls(to: android).filter { $0.ctl == MessageContent.Control.groupKeyRequest }
        #expect(requests.count == 1 && fixture.engine.groupCounts.groupKeyRequestsSent == 1, "the three ask once")
        // Android's answer re-seals its current seed (`redistributeGroupKey`); the iPhone's own answer is P6b's.
        fixture.deliver(try author.seedDm(to: me, prekey: try fixture.ourPrekey(), id: "seed-answer", sentAt: now + 10), from: android)
        #expect((1...3).map { fixture.stores.messages.message("sealed-\($0)")?.body } == ["sealed 1", "sealed 2", "sealed 3"])
        #expect(fixture.engine.groupCounts.groupKeyRequestsSent == 1)
    }

    @Test func aLeaveRekeysSeedThatOvertakesTheEarlierOneLosesNothing() throws {
        let fixture = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        let group = fixture.holdGroup(with: [alice, carol])
        let author = GroupFormAuthor(android, in: group.id)
        let earlier = author.seed
        let before = try author.frame(group, id: "g-before", body: "before the leave", sentAt: now)
        author.rekey(at: now + 1)
        let after = try author.frame(group, id: "g-after", body: "after the leave", sentAt: now + 2)
        let prekey = try fixture.ourPrekey()
        fixture.deliver(try author.seedDm(to: me, prekey: prekey, id: "seed-2", sentAt: now + 2), from: android)
        let late = MessageContent(body: "", ctl: MessageContent.Control.groupKey, gk: GroupKeyPayload(groupId: group.id, keys: [earlier]))
        fixture.deliver(try android.dm(late, to: me, prekey: prekey, id: "seed-1", sentAt: now + 3), from: android)
        fixture.deliver(after, from: alice)
        fixture.deliver(before, from: alice)
        #expect(fixture.stores.messages.message("g-before")?.body == "before the leave")
        #expect(fixture.stores.messages.message("g-after")?.body == "after the leave")
        #expect(fixture.engine.dropped[.groupRatchetAeadFail] == nil, "no seed was lost as stale")
    }

    @Test func aRejoinersSeedThatOutrunsTheRejoinFrameRejoinsThemItself() throws {
        let (lab, android) = try carried(holding: true)
        let group = lab[0].holdGroup(with: [alice])
        try lab[0].depart(alice, from: group, at: now + 10)
        let author = GroupFormAuthor(android, in: group.id)
        arrive(try author.seedDm(to: me, prekey: try lab[0].ourPrekey(), id: "seed-back", sentAt: now + 20, roster: group), at: 1, in: lab)
        arrive(try author.frame(group, id: "g-back", body: "i am back", sentAt: now + 21), at: 1, in: lab)
        lab.release(from: 1, to: 0) { $0.filter { !isGroupFrame($0) } }
        #expect(lab[0].roster(of: group).departed.isEmpty, "her own seed rejoined her")
        #expect(lab[0].engine.groupCounts.groupSeedsHeld == 0)
        lab.unlink(0, 1)
        lab.link(0, 1)
        #expect(lab[0].stores.messages.message("g-back")?.body == "i am back", "back-filled, opened on its first pass")
        #expect(lab[0].roster(of: group).departed.isEmpty)
    }
}
