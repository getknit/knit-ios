import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// The roster's rules for a frame replayed from our own custody (ADR 2026-10.5sk9, phase P7a). A replayed leave is not
/// replayed past its sender's later frame (``GroupRoster/outlives(_:leftAt:in:by:)``): only the leaver's own newer frame in
/// the same group that lists them counts, both on their clock, and a far-future stamp counts only up to our bound. A
/// replayed roster keeps the row on a tie (``GroupRoster/keepsTies``), where a first verdict gives it to the incoming
/// frame. Kotlin replays no roster frame, so it has neither rule.
@Suite struct GroupRosterReplayRulesTests {
    private let alice = TestPeer(seed: 1).nodeId
    private let bob = TestPeer(seed: 2).nodeId
    private let carol = TestPeer(seed: 3).nodeId

    private func info(_ members: [NodeId], departed: [NodeId] = []) -> GroupInfo {
        GroupInfo(
            id: GroupId.derive((members + departed).map(\.string)),
            members: members.map(\.string),
            createdBy: members[0].string,
            departed: departed.isEmpty ? nil : departed.map(\.string)
        )
    }

    @Test func onlyTheLeaversOwnNewerFrameThatListsThemOutlivesTheirLeave() {
        let group = info([bob, carol, alice])
        func frame(_ type: FrameType = .chat, from sender: NodeId? = nil, in held: GroupInfo? = nil, at sentAt: Int64) -> RelayEnvelope {
            RelayEnvelope(
                type: type, id: "f-\(sentAt)", senderId: (sender ?? carol).string, sentAt: sentAt, group: held ?? group, payload: [])
        }
        let roster = GroupRoster(me: alice, maxClock: 1000)
        func outlives(_ frames: [RelayEnvelope], leftAt: Int64 = 100) -> Bool {
            roster.outlives(carol, leftAt: leftAt, in: group.id, by: frames)
        }
        #expect(outlives([frame(at: 101)]) && outlives([frame(.groupUpdate, at: 101)]))
        #expect(!outlives([frame(at: 100)]), "no newer than the leave")
        #expect(!outlives([frame(from: bob, at: 200)]), "someone else's frame keeps nobody")
        #expect(!outlives([frame(in: info([carol, alice]), at: 200)]), "another group's")
        var unlisted = info([bob, alice], departed: [carol])
        unlisted.id = group.id
        #expect(!outlives([frame(in: unlisted, at: 200)]), "a frame that does not list them")
        #expect(!outlives([frame(.groupLeave, at: 200)]) && !outlives([frame(.reaction, at: 200)]), "only roster-carrying frames")
        #expect(!outlives([frame(at: 5000)], leftAt: 1000), "bounded to our clock's limit, as the leave is")
        #expect(outlives([frame(at: 5000)], leftAt: 999), "and still newer than a leave under it")
    }

    /// On a tie a first verdict takes the incoming name and a newer photo as Kotlin does; a replay keeps the row, and still
    /// takes a strictly newer name or photo.
    @Test func aReplayKeepsTheRowOnATieWhereAFirstVerdictTakesTheIncomingFrame() {
        var held = GroupRecord(
            id: "",
            name: "Hike",
            createdBy: bob.string,
            createdAt: 1,
            nameUpdatedAt: 100,
            photoHash: "aa",
            photoUpdatedAt: 100,
            roster: [bob, carol, alice].map { GroupMember(nodeId: $0.string) }
        )
        var frame = info([bob, carol, alice])
        held.id = frame.id
        frame.name = "Swim"
        frame.photoHash = "bb"
        frame.photoUpdatedAt = 100
        func verdict(keepsTies: Bool, at sentAt: Int64) -> GroupRecord? {
            guard
                case .accepted(let group, _) = GroupRoster(me: alice, maxClock: .max, keepsTies: keepsTies)
                    .reconcile(frame, from: carol, at: sentAt, existing: held)
            else {
                return nil
            }
            return group
        }
        #expect(verdict(keepsTies: false, at: 100)?.name == "Swim", "a first verdict's tie goes to the frame")
        #expect(verdict(keepsTies: true, at: 100) == held, "a replay's tie keeps the row")
        #expect(verdict(keepsTies: true, at: 101)?.name == "Swim")
        frame.photoUpdatedAt = 101
        #expect(verdict(keepsTies: true, at: 100)?.photoHash == "bb", "a strictly newer photo still wins")
    }

    /// Holding no photo, a replay takes one that came with no clock, as a first verdict does (the crypto review of P7a).
    @Test func aReplayTakesAPhotoWithNoClockWhenNoneIsHeld() {
        var frame = info([bob, carol, alice])
        frame.photoHash = "aa"
        let held = GroupRecord(
            id: frame.id, createdBy: bob.string, createdAt: 1, roster: [bob, carol, alice].map { GroupMember(nodeId: $0.string) })
        for keepsTies in [false, true] {
            let verdict = GroupRoster(me: alice, maxClock: .max, keepsTies: keepsTies).reconcile(
                frame, from: carol, at: 100, existing: held)
            guard case .accepted(let group, _) = verdict else {
                Issue.record("expected an accepted roster, got \(verdict)")
                continue
            }
            #expect(group.photoHash == "aa", "keepsTies \(keepsTies)")
        }
    }

    /// The durable half of the outlived rule: a message, rename or rejoin row of the leaver's own, newer than the leave on
    /// their clock and bounded as it is; never someone else's row, their own older one, or a line another's frame writes.
    @Test func onlyTheLeaversOwnNewerRowShowsThemActingAfterTheLeave() {
        let roster = GroupRoster(me: alice, maxClock: 1000)
        func row(_ kind: MessageKind = .message, by sender: NodeId? = nil, at sentAt: Int64) -> MessageRecord {
            MessageRecord(
                id: "m-\(sentAt)", senderId: sender ?? carol, recipientId: nil, conversationId: "g", body: "", sentAt: sentAt, kind: kind)
        }
        func acted(_ rows: [MessageRecord], leftAt: Int64 = 100) -> Bool {
            roster.actedAfter(carol, leftAt: leftAt, among: rows)
        }
        #expect(acted([row(at: 101)]) && acted([row(.groupRenamed, at: 101)]) && acted([row(.memberRejoined, at: 101)]))
        #expect(!acted([row(at: 100)]), "no newer than the leave")
        #expect(!acted([row(by: bob, at: 200)]), "someone else's row")
        #expect(!acted([row(.memberLeft, at: 200)]) && !acted([row(.groupCreated, at: 200)]), "a line another's frame can write")
        #expect(!acted([row(at: 5000)], leftAt: 1000), "bounded to our clock's limit, as the leave is")
    }
}
