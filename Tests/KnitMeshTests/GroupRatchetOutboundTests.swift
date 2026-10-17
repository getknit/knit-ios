import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The group form's send rules, pure (ADR 2026-10.5sk9, phase P6b): which form a frame takes (`groupRatchetEligible`,
/// `MeshManager.kt:1347-1353`), what a seed carries (`groupKeyPayload`, `:1500-1515`), when a seed is owed again
/// (`flushPendingGroupKeysFor`, `:1444-1470`), and the seed re-send and rejoin rekey floors (`seedSendFloorOpen`, `:1838-1849`;
/// `rejoinRekeyDue`, `InboundPipeline.kt:2311-2321`), at knit-next `cbf2a487`.
@Suite struct GroupRatchetOutboundTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let bob = TestPeer(seed: 3)

    /// `peer`'s pinned row, with `capabilities` and its prekey 1 unless told otherwise.
    private func row(_ peer: TestPeer, capabilities: Int64? = 0x15F, prekey: PrekeyInfo?? = nil) throws -> PeerRecord {
        var record = PeerRecord(nodeId: peer.nodeId, name: "", status: "", publicKey: peer.keys.bundle.encoded, updatedAt: 1)
        record.capabilities = capabilities
        record.prekey = try prekey ?? peer.prekey(id: 1)
        return record
    }

    private func member(_ peer: TestPeer, _ row: PeerRecord?) -> GroupRatchetOutbound.Member {
        GroupRatchetOutbound.Member(nodeId: peer.nodeId, row: row)
    }

    @Test func everyMemberWithTheBitAndAValidPrekeyTakesTheGroupForm() throws {
        let form = GroupRatchetOutbound.form(of: [member(alice, try row(alice)), member(bob, try row(bob))], ratchet: true)
        guard case .groupForm(let targets) = form else {
            Issue.record("expected the group form, got \(form)")
            return
        }
        #expect(targets.map(\.member) == [alice.nodeId, bob.nodeId] && targets.allSatisfy { $0.prekey != nil })
        #expect(form.bundles == [alice.nodeId: alice.keys.bundle, bob.nodeId: bob.keys.bundle], "the fallback's wraps")
    }

    @Test func anyShortfallSendsTheWholeFrameV1() throws {
        let capable = member(alice, try row(alice))
        let withoutTheBit = member(bob, try row(bob, capabilities: 0xF))
        let withoutCapabilities = member(bob, try row(bob, capabilities: nil))
        let withoutAPrekey = member(bob, try row(bob, prekey: .some(nil)))
        // A prekey another key signed, which a peer would refuse: as none.
        let forged = member(bob, try row(bob, prekey: .some(try alice.prekey(id: 1))))
        for other in [withoutTheBit, withoutCapabilities, withoutAPrekey, forged] {
            #expect(
                GroupRatchetOutbound.form(of: [capable, other], ratchet: true)
                    == .staticKeys([alice.nodeId: alice.keys.bundle, bob.nodeId: bob.keys.bundle], unkeyed: []))
        }
        let unpinned = GroupRatchetOutbound.form(of: [capable, member(bob, nil)], ratchet: true)
        #expect(unpinned == .staticKeys([alice.nodeId: alice.keys.bundle], unkeyed: [bob.nodeId]), "skipped from the wraps, asked for")
        let unparsed = GroupRatchetOutbound.Member(nodeId: nil, row: nil)
        #expect(
            GroupRatchetOutbound.form(of: [capable, unparsed], ratchet: true) == .staticKeys([alice.nodeId: alice.keys.bundle], unkeyed: [])
        )
    }

    @Test func theSwitchOffAndAnEmptyRosterAreV1() throws {
        #expect(
            GroupRatchetOutbound.form(of: [member(alice, try row(alice))], ratchet: false)
                == .staticKeys([alice.nodeId: alice.keys.bundle], unkeyed: []))
        #expect(GroupRatchetOutbound.form(of: [], ratchet: true) == .staticKeys([:], unkeyed: []))
    }

    @Test func aBlockedOrUnparsedMemberIsNoOneWeSendToButOurselvesNeverIs() {
        let roster = [
            GroupMember(nodeId: alice.nodeId.string), GroupMember(nodeId: me.nodeId.string),
            GroupMember(nodeId: bob.nodeId.string, departed: true),
        ]
        let group = GroupRecord(id: "g-1", createdBy: alice.nodeId.string, createdAt: 1, roster: roster)
        #expect(GroupRatchetOutbound.others(in: group, me: me.nodeId) == [alice.nodeId.string], "us and the departed left out")
    }

    @Test func aReSentSeedGoesToAnyPinnedBundleWithItsPrekeyIfOneVerifies() throws {
        #expect(GroupRatchetOutbound.seedTarget(alice.nodeId, row: nil) == nil, "no row, no bundle: nothing to seal to")
        let target = try #require(GroupRatchetOutbound.seedTarget(alice.nodeId, row: try row(alice, capabilities: 0xF)))
        #expect(target.bundle == alice.keys.bundle && target.prekey != nil, "no capability asked for, as Kotlin's `sendSeedDm`")
        let bare = try #require(GroupRatchetOutbound.seedTarget(alice.nodeId, row: try row(alice, prekey: .some(nil))))
        #expect(bare.prekey == nil, "a session held still seals without one")
    }

    @Test func aSeedCarriesTheFoundingRosterAndNoRootOrPhoto() {
        let roster = [GroupMember(nodeId: alice.nodeId.string), GroupMember(nodeId: me.nodeId.string)]
        let group = GroupRecord(
            id: "g-1",
            name: "Team",
            createdBy: alice.nodeId.string,
            createdAt: 1,
            photoHash: "ph1",
            photoUpdatedAt: 42,
            roster: roster
        )
        let seed = GroupSeed(epoch: 3, seed: Array(repeating: 7, count: 32), mintedAt: 9)
        let content = GroupRatchetOutbound.seed([seed], of: group)
        #expect(content.ctl == MessageContent.Control.groupKey && content.body.isEmpty)
        let founding = GroupInfo(id: "g-1", name: "Team", members: group.members, createdBy: alice.nodeId.string)
        #expect(content.gk == GroupKeyPayload(groupId: "g-1", keys: [seed], group: founding))
        #expect(content.gk?.gr == nil)
    }

    @Test func aSeedIsOwedUntilItsEpochIsAcknowledgedOrAResetForcesIt() {
        let newest = GroupSeed(epoch: 2, seed: Array(repeating: 1, count: 32), mintedAt: 5)
        let sent = GroupKeySendRecord(member: alice.nodeId, sentEpoch: 2, sentAt: 1, ackedEpoch: 1, ackedAt: 1)
        var acked = sent
        acked.ackedEpoch = 2
        #expect(GroupRatchetOutbound.seedOwed(newest: nil, outbox: nil, force: true) == nil, "no live chain, nothing to send")
        #expect(GroupRatchetOutbound.seedOwed(newest: newest, outbox: nil, force: false) == newest, "never sent")
        #expect(GroupRatchetOutbound.seedOwed(newest: newest, outbox: sent, force: false) == newest, "an older epoch acknowledged")
        #expect(GroupRatchetOutbound.seedOwed(newest: newest, outbox: acked, force: false) == nil)
        #expect(GroupRatchetOutbound.seedOwed(newest: newest, outbox: acked, force: true) == newest, "a reset's ack predates the wipe")
    }

    @Test func theSeedFloorHoldsFifteenMinutesPerGroupMemberAndRoot() {
        var floors = GroupSendFloors()
        #expect(floors.seedMayGo(in: "g-1", to: alice.nodeId, root: 1, now: 0))
        floors.seedWent(in: "g-1", to: alice.nodeId, root: 1, now: 0)
        let floor = GroupRatchetOutbound.seedResendMilliseconds
        #expect(!floors.seedMayGo(in: "g-1", to: alice.nodeId, root: 1, now: floor - 1), "the same root, inside the floor")
        #expect(floors.seedMayGo(in: "g-1", to: alice.nodeId, root: 1, now: floor))
        #expect(floors.seedMayGo(in: "g-1", to: alice.nodeId, root: 2, now: 1), "a root the member has left holds nothing back")
        #expect(floors.seedMayGo(in: "g-1", to: alice.nodeId, root: nil, now: 1), "nor does losing the session")
        #expect(
            floors.seedMayGo(in: "g-1", to: bob.nodeId, root: 1, now: 1) && floors.seedMayGo(in: "g-2", to: alice.nodeId, root: 1, now: 1))
        // A group id is compared by its bytes: U+212A KELVIN SIGN is another group than K.
        floors.seedWent(in: "g-K", to: bob.nodeId, root: nil, now: 0)
        #expect(floors.seedMayGo(in: "g-\u{212A}", to: bob.nodeId, root: nil, now: 1))
        #expect(floor == 900_000, "SEED_RESEND_FLOOR_MS")
    }

    @Test func theRejoinRekeyIsDueOncePerHourPerGroupAndMember() {
        var floors = GroupSendFloors()
        #expect(floors.rekeyDue(in: "g-1", for: alice.nodeId, now: 0))
        floors.rekeyed(in: "g-1", for: alice.nodeId, now: 0)
        let hour = GroupRatchetOutbound.rejoinRekeyMilliseconds
        #expect(!floors.rekeyDue(in: "g-1", for: alice.nodeId, now: hour - 1))
        #expect(floors.rekeyDue(in: "g-1", for: alice.nodeId, now: hour))
        #expect(floors.rekeyDue(in: "g-1", for: bob.nodeId, now: 1))
        #expect(hour == 3_600_000, "REJOIN_REKEY_FLOOR_MS")
    }

    @Test func aRejoinIsOnlyTheSendersOwnReturn() {
        let gone = GroupMember(nodeId: alice.nodeId.string, departed: true, leftAt: 5)
        let back = GroupMember(nodeId: alice.nodeId.string, rejoinedAt: 9)
        let mine = GroupMember(nodeId: me.nodeId.string)
        let before = GroupRecord(id: "g-1", createdBy: me.nodeId.string, createdAt: 1, roster: [mine, gone])
        let after = GroupRecord(id: "g-1", createdBy: me.nodeId.string, createdAt: 1, roster: [mine, back])
        #expect(GroupRoster.rejoined(alice.nodeId, from: before, to: after))
        #expect(!GroupRoster.rejoined(alice.nodeId, from: after, to: after), "already present")
        #expect(!GroupRoster.rejoined(alice.nodeId, from: nil, to: after), "a first sight is no rejoin")
        #expect(!GroupRoster.rejoined(bob.nodeId, from: before, to: after))
    }
}
