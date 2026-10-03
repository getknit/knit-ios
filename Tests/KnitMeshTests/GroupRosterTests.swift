import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// The roster rules, ported from knit-next's `InboundPipelineTest` (roster vetting, `:1818-2016`; rejoin, `:6257-6412`)
/// and `GroupRepositoryTest` (ADR 2026-09.n393).
@Suite struct GroupRosterTests {
    private typealias Verdict = GroupRoster.Verdict

    private let alice = TestPeer(seed: 1).nodeId
    private let bob = TestPeer(seed: 2).nodeId
    private let carol = TestPeer(seed: 3).nodeId
    private let dave = TestPeer(seed: 4).nodeId

    private func info(_ members: [NodeId], departed: [NodeId] = [], name: String? = nil, createdBy: NodeId? = nil) -> GroupInfo {
        let founding = (members + departed).map(\.string)
        return GroupInfo(
            id: GroupId.derive(founding),
            name: name,
            members: members.map(\.string),
            createdBy: (createdBy ?? members.first ?? alice).string,
            departed: departed.isEmpty ? nil : departed.map(\.string)
        )
    }

    private func reconcile(_ info: GroupInfo, from sender: NodeId, at sentAt: Int64 = 100, existing: GroupRecord? = nil) -> Verdict {
        GroupRoster(me: alice, maxClock: .max).reconcile(info, from: sender, at: sentAt, existing: existing)
    }

    private func accepted(_ verdict: Verdict) throws -> (GroupRecord, [MessageRecord]) {
        guard case .accepted(let group, let notices) = verdict else {
            Issue.record("expected an accepted roster, got \(verdict)")
            throw GroupRosterTestError.notAccepted
        }
        return (group, notices)
    }

    // MARK: First sight

    @Test func aFirstSightPinsTheRosterAndSaysWhoCreatedIt() throws {
        let frame = info([bob, carol, alice], name: "Hikers", createdBy: bob)
        let (group, notices) = try accepted(reconcile(frame, from: carol, at: 50))
        #expect(group.id == frame.id && group.name == "Hikers" && group.nameUpdatedAt == 50)
        #expect(group.members == [bob, carol, alice].map(\.string) && group.departed.isEmpty)
        #expect(group.createdBy == bob.string && group.createdAt == 50 && !group.hasLeft)
        #expect(notices == [StatusNotices.groupCreated(frame.id, by: bob, at: 50)], "created, not renamed")
    }

    /// `aFirstSightWithDepartedTombstonesVerifiesTheFoundingSet`: the frame's departed list completes the hash, and is
    /// never taken as our tombstones, so we keep wrapping to them until their own leave reaches us.
    @Test func aFirstSightCountsTheDepartedButTakesNoTombstones() throws {
        let frame = info([bob, alice], departed: [carol])
        let (group, _) = try accepted(reconcile(frame, from: bob))
        #expect(group.members == [bob, alice, carol].map(\.string))
        #expect(group.departed.isEmpty)
    }

    @Test func aFirstSightTakesTheFramesPhoto() throws {
        var frame = info([bob, alice])
        frame.photoHash = "p1"
        frame.photoUpdatedAt = 7
        let (group, _) = try accepted(reconcile(frame, from: bob))
        #expect(group.photoHash == "p1" && group.photoUpdatedAt == 7)
    }

    @Test func aGroupWeAreNotInIsOnlyCarried() {
        #expect(reconcile(info([bob, carol]), from: bob) == .ignored)
    }

    @Test func aRosterThatDoesNotHashToItsIdIsRefused() {
        var forged = info([bob, alice])
        forged.id = GroupId.derive([bob.string, carol.string])
        #expect(reconcile(forged, from: bob) == .refused)
    }

    @Test func aRosterOverEightIsRefused() {
        let crowd = (5...12).map { TestPeer(seed: $0).nodeId }
        #expect(reconcile(info([bob, alice] + crowd), from: bob) == .refused)
    }

    @Test func aSenderOutsideTheFoundingSetIsRefused() {
        #expect(reconcile(info([bob, alice]), from: carol) == .refused)
    }

    // MARK: The pin

    private func held(_ members: [NodeId], departed: [GroupMember] = [], name: String = "", nameClock: Int64 = 0) -> GroupRecord {
        let founding = members.map(\.string) + departed.map(\.nodeId)
        return GroupRecord(
            id: GroupId.derive(founding),
            name: name,
            createdBy: bob.string,
            createdAt: 10,
            nameUpdatedAt: nameClock,
            roster: members.map { GroupMember(nodeId: $0.string) } + departed
        )
    }

    @Test func aMemberCannotBeSmuggledIntoThePin() {
        let pinned = held([bob, carol, alice])
        var smuggled = info([bob, carol, alice, dave])
        smuggled.id = pinned.id
        #expect(reconcile(smuggled, from: bob, existing: pinned) == .refused)
    }

    @Test func aShrunkRosterIsAcceptedButNeverShrinksThePin() throws {
        let pinned = held([bob, carol, alice])
        var shrunk = info([bob, alice])
        shrunk.id = pinned.id
        let (group, notices) = try accepted(reconcile(shrunk, from: bob, existing: pinned))
        #expect(group.members == pinned.members)
        #expect(notices.isEmpty)
    }

    @Test func aFrameLeavingUsOutStillDeliversToUs() throws {
        let pinned = held([bob, carol, alice])
        var withoutUs = info([bob, carol])
        withoutUs.id = pinned.id
        let (group, _) = try accepted(reconcile(withoutUs, from: carol, existing: pinned))
        #expect(group.members == pinned.members)
    }

    /// `aVerifiedSupersetRepairsATruncatedPin`: only the true founding set can widen a pin, since the id is its hash.
    @Test func aVerifiedSupersetRepairsAPinMadeFromATruncatedFrame() throws {
        let full = info([bob, carol, alice])
        let truncated = GroupRecord(
            id: full.id,
            createdBy: bob.string,
            createdAt: 10,
            roster: [GroupMember(nodeId: bob.string), GroupMember(nodeId: alice.string)]
        )
        let (group, _) = try accepted(reconcile(full, from: bob, existing: truncated))
        #expect(group.members == [bob, carol, alice].map(\.string))
    }

    @Test func aVerifiedSupersetKeepsOurTombstones() throws {
        let frame = info([bob, carol, alice], departed: [dave])
        let truncated = GroupRecord(
            id: frame.id,
            createdBy: bob.string,
            createdAt: 10,
            roster: [
                GroupMember(nodeId: bob.string), GroupMember(nodeId: alice.string),
                GroupMember(nodeId: dave.string, departed: true, leftAt: 5),
            ]
        )
        let (group, _) = try accepted(reconcile(frame, from: bob, existing: truncated))
        #expect(group.members == [bob, carol, alice].map(\.string))
        #expect(group.departed == [dave.string] && group.member(dave.string)?.leftAt == 5)
    }

    @Test func aGroupWeLeftIsNeverBroughtBack() {
        var left = held([bob, alice])
        left.hasLeft = true
        #expect(reconcile(info([bob, alice]), from: bob, existing: left) == .ignored)
    }

    // MARK: Names and photos

    @Test func theNewerNameWinsAndATieGoesToTheFrame() throws {
        let pinned = held([bob, alice], name: "Old", nameClock: 100)
        func name(_ text: String?, at sentAt: Int64) throws -> (String, [MessageRecord]) {
            var frame = info([bob, alice], name: text)
            frame.id = pinned.id
            let (group, notices) = try accepted(reconcile(frame, from: bob, at: sentAt, existing: pinned))
            return (group.name, notices)
        }
        #expect(try name("Older", at: 99).0 == "Old")
        #expect(try name("Tied", at: 100).0 == "Tied")
        #expect(try name(nil, at: 200).0 == "Old", "an unnamed frame never clears the name")
        #expect(try name("  ", at: 200).0 == "Old", "nor does a blank one")
        let (newName, notices) = try name(String(repeating: "n", count: 40), at: 200)
        #expect(newName == String(repeating: "n", count: 32))
        #expect(notices == [StatusNotices.groupRenamed(pinned.id, by: bob, to: newName, at: 200)])
        #expect(try name("Old", at: 300).1.isEmpty, "the same name again is no rename")
    }

    @Test func aNewPhotoIsTakenAtOnceAndAnOlderOneIsNot() throws {
        var pinned = held([bob, alice])
        pinned.photoHash = "old"
        pinned.photoUpdatedAt = 100
        func photo(_ hash: String?, clock: Int64?) throws -> GroupRecord {
            var frame = info([bob, alice])
            frame.id = pinned.id
            frame.photoHash = hash
            frame.photoUpdatedAt = clock
            return try accepted(reconcile(frame, from: bob, existing: pinned)).0
        }
        let newer = try photo("new", clock: 200)
        #expect(newer.photoHash == "new" && newer.photoUpdatedAt == 200, "the decided photo is taken before its bytes land")
        #expect(try photo("stale", clock: 99).photoHash == "old")
        #expect(try photo("old", clock: 400).photoUpdatedAt == 100, "the held photo again does not move its clock")
        #expect(try photo(nil, clock: 300).photoHash == "old", "no photo on a frame never clears one")
        var distant = info([bob, alice])
        distant.id = pinned.id
        distant.photoHash = "distant"
        distant.photoUpdatedAt = .max
        let clamped = GroupRoster(me: alice, maxClock: 500).reconcile(distant, from: bob, at: 100, existing: pinned)
        #expect(try accepted(clamped).0.photoUpdatedAt == 500, "a far-future photo clock is bounded")
    }

    /// `photoWins` (`InboundPipeline.kt:2378`, knit-next ADR 2026-09.nxcq): a member still showing the old photo
    /// re-asserts it at the new clock, so a tie that went to the frame switched the group back (#108).
    @Test func aTieKeepsTheHeldPhotoAndTakesOneOnlyWhenNoneIsHeld() throws {
        var pinned = held([bob, alice])
        pinned.photoHash = "old"
        pinned.photoUpdatedAt = 100
        var tied = info([bob, alice])
        tied.id = pinned.id
        tied.photoHash = "tied"
        tied.photoUpdatedAt = 100
        #expect(try accepted(reconcile(tied, from: bob, existing: pinned)).0.photoHash == "old")
        var unstamped = info([bob, alice])
        unstamped.photoHash = "first"
        let bare = held([bob, alice])
        unstamped.id = bare.id
        #expect(try accepted(reconcile(unstamped, from: bob, existing: bare)).0.photoHash == "first", "nothing held: a tie takes")
        #expect(GroupRoster.photoWins(nil, at: 900, over: nil, at: 0) == false, "no photo on a frame takes nothing")
    }

    // MARK: Leaving and coming back

    @Test func aMemberLeavesOnlyByTheirOwnNewerLeave() throws {
        let pinned = held([bob, carol, alice])
        let departure = try #require(GroupRoster.depart(carol, at: 50, from: pinned))
        #expect(departure.group.members == [bob, alice].map(\.string))
        #expect(departure.group.departed == [carol.string])
        #expect(departure.group.member(carol.string)?.leftAt == 50)
        #expect(departure.notice == StatusNotices.memberLeft(pinned.id, member: carol, at: 50))
        #expect(GroupRoster.depart(carol, at: 60, from: departure.group) == nil, "already gone")
        #expect(GroupRoster.depart(dave, at: 60, from: pinned) == nil, "never a member")
        var left = pinned
        left.hasLeft = true
        #expect(GroupRoster.depart(carol, at: 60, from: left) == nil, "a group we left")
        var rejoined = pinned
        rejoined.roster[1].rejoinedAt = 70
        #expect(GroupRoster.depart(carol, at: 70, from: rejoined) == nil, "a leave no newer than the rejoin")
        #expect(GroupRoster.depart(carol, at: 71, from: rejoined) != nil)
    }

    @Test func aMemberWhoLeftComesBackByTheirOwnNewerFrame() throws {
        let pinned = held([bob, alice], departed: [GroupMember(nodeId: carol.string, departed: true, leftAt: 50)])
        var frame = info([bob, carol, alice])
        frame.id = pinned.id
        let (group, notices) = try accepted(reconcile(frame, from: carol, at: 60, existing: pinned))
        #expect(group.members == [bob, alice, carol].map(\.string), "back at the end of the roster")
        #expect(group.member(carol.string)?.rejoinedAt == 60)
        #expect(group.member(carol.string)?.leftAt == 50)
        #expect(notices == [StatusNotices.memberRejoined(pinned.id, member: carol, at: 60)])
    }

    @Test func aMemberWhoLeftWithNoClockOnFileComesBackOnAnyFrameOfTheirs() throws {
        let pinned = held([bob, alice], departed: [GroupMember(nodeId: carol.string, departed: true)])
        var frame = info([bob, carol, alice])
        frame.id = pinned.id
        let (group, _) = try accepted(reconcile(frame, from: carol, at: 1, existing: pinned))
        #expect(group.departed.isEmpty)
    }

    @Test func aReservedFrameFromBeforeTheLeaveDoesNotUndoIt() throws {
        let pinned = held([bob, alice], departed: [GroupMember(nodeId: carol.string, departed: true, leftAt: 50)])
        var frame = info([bob, carol, alice])
        frame.id = pinned.id
        let (group, notices) = try accepted(reconcile(frame, from: carol, at: 40, existing: pinned))
        #expect(group.departed == [carol.string])
        #expect(notices.isEmpty)
    }

    @Test func nobodyBringsBackSomeoneElse() throws {
        let pinned = held([bob, alice], departed: [GroupMember(nodeId: carol.string, departed: true, leftAt: 50)])
        var frame = info([bob, carol, alice])
        frame.id = pinned.id
        let (group, _) = try accepted(reconcile(frame, from: bob, at: 60, existing: pinned))
        #expect(group.departed == [carol.string])
    }

    @Test func aFrameThatDoesNotListTheLeaverBringsNobodyBack() throws {
        let pinned = held([bob, alice], departed: [GroupMember(nodeId: carol.string, departed: true, leftAt: 50)])
        var frame = info([bob, alice], departed: [carol])
        frame.id = pinned.id
        let (group, _) = try accepted(reconcile(frame, from: carol, at: 60, existing: pinned))
        #expect(group.departed == [carol.string])
    }

    // MARK: Who the created line names

    /// Android names `createdBy` unchecked, so a stranger naming us made the line, and the group, ours.
    @Test func theCreatedLineNeverNamesUsForSomeoneElsesFrame() throws {
        let forged = info([bob, alice], createdBy: alice)
        #expect(try accepted(reconcile(forged, from: bob)).1.first?.senderId == bob)
        #expect(try accepted(reconcile(forged, from: alice)).1.first?.senderId == alice, "our own frame, re-served")
        let outsider = info([bob, alice], createdBy: carol)
        #expect(try accepted(reconcile(outsider, from: bob)).1.first?.senderId == bob, "a creator outside the roster")
        var unparsed = info([bob, alice])
        unparsed.createdBy = "not a node id"
        #expect(try accepted(reconcile(unparsed, from: bob)).1.first?.senderId == bob)
    }
}

private enum GroupRosterTestError: Error {
    case notAccepted
}
