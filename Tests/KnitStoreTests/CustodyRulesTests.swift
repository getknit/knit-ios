import KnitCrypto
import KnitStore
import KnitWire
import Testing

/// The pure custody rules every store applies.
@Suite struct CustodyRulesTests {
    private let limits = CustodyLimits()

    private func envelope(sentAt: Int64, recipient: String? = nil, type: FrameType = .chat) -> RelayEnvelope {
        RelayEnvelope(type: type, id: "m1", senderId: "a", sentAt: sentAt, recipientId: recipient, payload: [])
    }

    /// `envelope` as custody is handed it: its own bytes, unsigned.
    private func carried(_ envelope: RelayEnvelope) -> CarriedFrame {
        CarriedFrame(envelope: envelope, sig: [], signed: envelope.encoded)
    }

    @Test func roomPostsLastSixHoursAndEverythingElseADay() {
        let sixHours: Int64 = 10 + 21_600_000
        let aDay: Int64 = 10 + 86_400_000
        #expect(CustodyRules.expiry(of: envelope(sentAt: 10), now: 10, limits: limits) == sixHours)
        #expect(CustodyRules.expiry(of: envelope(sentAt: 10, recipient: "b"), now: 10, limits: limits) == aDay)
        for type in [FrameType.receipt, .reaction, .profile] {
            #expect(CustodyRules.expiry(of: envelope(sentAt: 10, type: type), now: 10, limits: limits) == aDay)
        }
    }

    @Test func aSentAtAtEitherEndOfTheRangeIsRefusedWithoutTrapping() {
        // Kotlin wraps the addition, which lands a huge sentAt in the past; the same refusal here, and no trap.
        #expect(CustodyRules.expiry(of: envelope(sentAt: .max), now: 1000, limits: limits) == nil)
        #expect(CustodyRules.expiry(of: envelope(sentAt: .min), now: 1000, limits: limits) == nil)
    }

    @Test func theFutureWindowIsFiveMinutesInclusive() {
        let now: Int64 = 1_756_200_000_000
        #expect(CustodyRules.expiry(of: envelope(sentAt: now + 300_000), now: now, limits: limits) != nil)
        #expect(CustodyRules.expiry(of: envelope(sentAt: now + 300_001), now: now, limits: limits) == nil)
    }

    @Test func evictionOrdersIdsByTheirBytesNotByCanonicalEquivalence() {
        func entry(_ id: String, sentAt: Int64 = 1) -> CustodyRules.Entry {
            CustodyRules.Entry(id: id, senderId: "a", groupId: nil, isRoomChat: false, sentAt: sentAt, expiresAt: 100)
        }
        // SQLite's BINARY collation is memcmp, so uppercase sorts before lowercase and "-" before "_".
        #expect(CustodyRules.evictsBefore(entry("B"), entry("a")))
        #expect(CustodyRules.evictsBefore(entry("-x"), entry("_x")))
        // Swift calls these two equal; their bytes are 65 CC 81 and C3 A9, and the byte order decides.
        #expect(CustodyRules.evictsBefore(entry("e\u{301}"), entry("\u{E9}")))
        #expect(!CustodyRules.evictsBefore(entry("\u{E9}"), entry("e\u{301}")))
        #expect(CustodyRules.evictsBefore(entry("z", sentAt: 1), entry("a", sentAt: 2)), "sentAt decides first")
    }

    @Test func anEvictedIdTakesOnlyItsOwnBytesOutOfTheCount() {
        // Swift calls "idK" and "id\u{212A}" (the Kelvin sign) equal. Evicting A's "idK" to the sender quota must
        // leave B's frame in the count, or the overall trim sees one frame too few and keeps what Android evicts.
        let live = [
            CustodyRules.Entry(id: "idK", senderId: "A", groupId: nil, isRoomChat: false, sentAt: 1, expiresAt: 100),
            CustodyRules.Entry(id: "idX", senderId: "A", groupId: nil, isRoomChat: false, sentAt: 2, expiresAt: 100),
            CustodyRules.Entry(id: "id\u{212A}", senderId: "B", groupId: nil, isRoomChat: false, sentAt: 3, expiresAt: 100),
        ]
        let evicted = CustodyRules.evictions(after: live[1], among: live, limits: CustodyLimits(maxFrames: 1, maxPerSender: 1))
        #expect(evicted.map { Array($0.utf8) } == [Array("idK".utf8), Array("idX".utf8)], "compared by bytes, as the rule must")
    }

    @Test func groupsThatSwiftCallsEqualAreTwoBuckets() {
        // A sender picks its group ids freely. One canonically equivalent to another group's must not share that
        // group's quota, which Android counts by code units.
        func entry(_ id: String, group: String, sentAt: Int64) -> CustodyRules.Entry {
            CustodyRules.Entry(id: id, senderId: id, groupId: group, isRoomChat: false, sentAt: sentAt, expiresAt: 100)
        }
        let real = entry("real", group: "caf\u{E9}", sentAt: 1)
        let crafted = entry("crafted", group: "cafe\u{301}", sentAt: 2)
        #expect(CustodyRules.evictions(after: crafted, among: [real, crafted], limits: CustodyLimits(maxPerGroup: 1)).isEmpty)
    }

    @Test func anEntryReadsItsBucketsOffTheEnvelope() {
        let group = GroupInfo(id: "g1", members: ["a"], createdBy: "a")
        let grouped = RelayEnvelope(type: .chat, id: "g", senderId: "a", sentAt: 5, group: group, payload: [])
        let entry = CustodyRules.Entry(grouped, expiresAt: 9)
        #expect(entry == CustodyRules.Entry(id: "g", senderId: "a", groupId: "g1", isRoomChat: false, sentAt: 5, expiresAt: 9))
        #expect(CustodyRules.Entry(envelope(sentAt: 1), expiresAt: 2).isRoomChat)
    }

    // MARK: The global cap's fair trim (knit-next ADR 2026-10.7mqm)

    private func entry(_ id: String, _ sender: String, sentAt: Int64, group: String? = nil, room: Bool = false) -> CustodyRules.Entry {
        CustodyRules.Entry(id: id, senderId: sender, groupId: group, isRoomChat: room, sentAt: sentAt, expiresAt: 1000)
    }

    @Test func theLargestSenderLosesItsOldestFrame() {
        let live = [entry("b1", "B", sentAt: 1), entry("a2", "A", sentAt: 2), entry("a3", "A", sentAt: 3)]
        #expect(CustodyRules.evictions(after: live[2], among: live, limits: CustodyLimits(maxFrames: 2)) == ["a2"])
    }

    @Test func aTieForMostGoesToTheSenderWhoseOldestFrameIsOldest() {
        let live = [entry("a5", "A", sentAt: 5), entry("a6", "A", sentAt: 6), entry("b4", "B", sentAt: 4), entry("b9", "B", sentAt: 9)]
        #expect(CustodyRules.evictions(after: live[3], among: live, limits: CustodyLimits(maxFrames: 3)) == ["b4"])
        // On a tie in sentAt too, the smaller id's bytes.
        let tied = [entry("y", "A", sentAt: 1), entry("x", "B", sentAt: 1)]
        #expect(CustodyRules.evictions(after: tied[0], among: tied, limits: CustodyLimits(maxFrames: 1)) == ["x"])
    }

    @Test func theCountsAreRecountedBetweenEvictions() {
        // A holds three and B two. The first eviction takes A's oldest; then both hold two, and B's oldest is older than
        // A's next, so B pays the second. Counting once would take two of A's.
        let live = [
            entry("a1", "A", sentAt: 10), entry("a2", "A", sentAt: 20), entry("a3", "A", sentAt: 30),
            entry("b1", "B", sentAt: 15), entry("b2", "B", sentAt: 40),
        ]
        #expect(CustodyRules.evictions(after: live[4], among: live, limits: CustodyLimits(maxFrames: 3)) == ["a1", "b1"])
    }

    @Test func theBucketTrimsStayNewestNWhoeverWroteTheFrames() {
        // The room holds A's three posts and B's one; its quota of three takes the oldest post, though A holds the most.
        let room = [
            entry("b1", "B", sentAt: 1, room: true), entry("a2", "A", sentAt: 2, room: true), entry("a3", "A", sentAt: 3, room: true),
            entry("a4", "A", sentAt: 4, room: true),
        ]
        #expect(CustodyRules.evictions(after: room[3], among: room, limits: CustodyLimits(maxRoomChat: 3)) == ["b1"])
        let group = [
            entry("g1", "B", sentAt: 1, group: "g"), entry("g2", "A", sentAt: 2, group: "g"), entry("g3", "A", sentAt: 3, group: "g"),
        ]
        #expect(CustodyRules.evictions(after: group[2], among: group, limits: CustodyLimits(maxPerGroup: 2)) == ["g1"])
        let sender = [entry("s1", "A", sentAt: 1), entry("s2", "A", sentAt: 2)]
        #expect(CustodyRules.evictions(after: sender[1], among: sender, limits: CustodyLimits(maxPerSender: 1)) == ["s1"])
    }

    @Test func sendersThatSwiftCallsEqualAreTwoBucketsInTheFairTrim() {
        // "e\u{301}" and "\u{E9}" are one String to Swift and two senders to Android's GROUP BY. As two buckets, the
        // composed sender holds two frames and loses its oldest; as one bucket of three, the oldest frame of all would go.
        let decomposed = "e\u{301}"
        let composed = "\u{E9}"
        let live = [entry("d1", decomposed, sentAt: 1), entry("c2", composed, sentAt: 2), entry("c3", composed, sentAt: 3)]
        #expect(CustodyRules.evictions(after: live[2], among: live, limits: CustodyLimits(maxFrames: 2)) == ["c2"])
    }

    // MARK: The group gate (knit-next ADR 2026-10.7mqm)

    private func grouped(_ sender: String, _ group: GroupInfo?) -> RelayEnvelope {
        RelayEnvelope(type: .chat, id: "g", senderId: sender, sentAt: 10, group: group, payload: [])
    }

    private let founders = ["alice", "bob", "carol"]

    @Test func aMemberUnderTheFoundingRosterIsAdmitted() {
        let group = GroupInfo(id: GroupId.derive(founders), members: founders, createdBy: "alice")
        #expect(
            CustodyRules.admission(of: carried(grouped("bob", group)), now: 10, limits: limits) == .admitted(expiresAt: 10 + 86_400_000))
        #expect(CustodyRules.carriesGroup(group, from: "bob"))
    }

    @Test func aStrangerNamingTheGroupIsRefused() {
        let group = GroupInfo(id: GroupId.derive(founders), members: founders, createdBy: "alice")
        #expect(CustodyRules.admission(of: carried(grouped("mallory", group)), now: 10, limits: limits) == .refused(.foreignRoster))
    }

    @Test func aSmuggledMemberNoLongerDerivesAndIsRefused() {
        let group = GroupInfo(id: GroupId.derive(founders), members: founders + ["mallory"], createdBy: "alice")
        #expect(!CustodyRules.carriesGroup(group, from: "mallory"))
        #expect(!CustodyRules.carriesGroup(group, from: "alice"), "the roster is wrong whoever sends under it")
    }

    @Test func aPreDepartedRosterAfterADepartureIsRefusedAndOneWithDepartedPasses() {
        let truncated = GroupInfo(id: GroupId.derive(founders), members: ["alice", "carol"], createdBy: "alice")
        #expect(!CustodyRules.carriesGroup(truncated, from: "alice"), "a pre-2.3.0 frame lists no departed")
        var current = truncated
        current.departed = ["bob"]
        #expect(CustodyRules.carriesGroup(current, from: "carol"))
        #expect(!CustodyRules.carriesGroup(current, from: "bob"), "a departed member is not a member")
    }

    @Test func aSenderCanonicallyEqualToAMemberButDifferentInBytesIsRefused() {
        let members = ["caf\u{E9}", "bob"]
        let group = GroupInfo(id: GroupId.derive(members), members: members, createdBy: "bob")
        #expect(CustodyRules.carriesGroup(group, from: "caf\u{E9}"))
        #expect(!CustodyRules.carriesGroup(group, from: "cafe\u{301}"))
    }

    @Test func aFrameWithNoGroupPassesTheGate() {
        #expect(
            CustodyRules.admission(of: carried(grouped("anyone", nil)), now: 10, limits: limits) == .admitted(expiresAt: 10 + 21_600_000))
    }

    @Test func theRefusalsComeInKotlinsOrder() {
        // A group frame that is dead, or ahead of the window, is refused for its time first, as `ForwardRepository.store`
        // checks it, so the roster counter never counts it.
        let foreign = GroupInfo(id: "g-0", members: ["x"], createdBy: "x")
        var dead = grouped("mallory", foreign)
        dead.sentAt = 0
        #expect(CustodyRules.admission(of: carried(dead), now: 1_756_200_000_000, limits: limits) == .refused(.deadOnArrival))
        var ahead = grouped("mallory", foreign)
        ahead.sentAt = 10 + 300_001
        #expect(CustodyRules.admission(of: carried(ahead), now: 10, limits: limits) == .refused(.aheadOfWindow))
        #expect(CustodyRules.admission(of: carried(grouped("mallory", foreign)), now: 10, limits: limits) == .refused(.foreignRoster))
    }

    // MARK: The byte cap (knit-next #227)

    @Test func theByteCapIsAndroidsSixtyKibibytes() {
        #expect(CustodyLimits().maxSignedBytes == 61_440, "`ForwardRepository.DEFAULT_MAX_SIGNED_BYTES`")
    }

    /// `envelope` padded with a chat body to exactly `signedBytes` of `signed`, the body's length searched upward: CBOR's
    /// length prefixes grow at 24, 256 and 65,536, so no fixed offset holds (`CustodyVectorTest.sized`).
    private func sized(_ signedBytes: Int, _ envelope: RelayEnvelope) throws -> CarriedFrame {
        var padded = envelope
        for length in 0...signedBytes {
            padded.payload = ChatContent(body: String(repeating: "x", count: length)).encoded
            if padded.encoded.count >= signedBytes {
                break
            }
        }
        try #require(padded.encoded.count == signedBytes, "no body length makes \(signedBytes) signed bytes")
        return carried(padded)
    }

    @Test func exactlyTheCapIsAdmittedAndOneByteOverIsRefused() throws {
        let tight = CustodyLimits(maxSignedBytes: 2048)
        let base = envelope(sentAt: 10, recipient: "b")
        #expect(CustodyRules.admission(of: try sized(2048, base), now: 10, limits: tight) == .admitted(expiresAt: 10 + 86_400_000))
        #expect(CustodyRules.admission(of: try sized(2049, base), now: 10, limits: tight) == .refused(.oversize))
    }

    @Test func theSignatureIsNotCounted() throws {
        let tight = CustodyLimits(maxSignedBytes: 2048)
        var frame = try sized(2048, envelope(sentAt: 10, recipient: "b"))
        frame.sig = [UInt8](repeating: 7, count: 64)
        #expect(CustodyRules.admission(of: frame, now: 10, limits: tight) == .admitted(expiresAt: 10 + 86_400_000))
    }

    @Test func theByteCapComesFirstInKotlinsOrder() throws {
        // `ForwardRepository.store` checks the size before anything else, so an oversize frame that also fails the clock or
        // the roster is counted as oversize, and the roster counter never moves for it.
        let tight = CustodyLimits(maxSignedBytes: 2048)
        let foreign = GroupInfo(id: "g-0", members: ["x"], createdBy: "x")
        #expect(CustodyRules.admission(of: try sized(2049, grouped("mallory", foreign)), now: 10, limits: tight) == .refused(.oversize))
        var dead = grouped("a", nil)
        dead.sentAt = 0
        #expect(CustodyRules.admission(of: try sized(2049, dead), now: 1_756_200_000_000, limits: tight) == .refused(.oversize))
        var ahead = grouped("a", nil)
        ahead.sentAt = 10 + 300_001
        #expect(CustodyRules.admission(of: try sized(2049, ahead), now: 10, limits: tight) == .refused(.oversize))
        #expect(CustodyRules.admission(of: try sized(2048, dead), now: 1_756_200_000_000, limits: tight) == .refused(.deadOnArrival))
    }

    // MARK: The profile cap

    @Test func theProfileCapIsEightKibibytes() {
        #expect(CustodyLimits().maxProfileSignedBytes == 8192, "the contract's 8 KiB, Android's fast and LoRa frame ceiling")
    }

    @Test func aProfileAtTheProfileCapIsAdmittedAndOneByteOverIsRefused() throws {
        let profile = envelope(sentAt: 10, type: .profile)
        let atCap = try sized(limits.maxProfileSignedBytes, profile)
        #expect(CustodyRules.admission(of: atCap, now: 10, limits: limits) == .admitted(expiresAt: 10 + 86_400_000))
        let over = try sized(limits.maxProfileSignedBytes + 1, profile)
        #expect(CustodyRules.admission(of: over, now: 10, limits: limits) == .refused(.profileOversize))
        #expect(CustodyRules.isOversizeProfile(type: .profile, signedCount: limits.maxProfileSignedBytes + 1, limits: limits))
        #expect(!CustodyRules.isOversizeProfile(type: .profile, signedCount: limits.maxProfileSignedBytes, limits: limits))
    }

    @Test func everyOtherTypeOfTheSameSizeIsAdmitted() throws {
        let size = limits.maxProfileSignedBytes + 1
        for type in [FrameType.chat, .receipt, .reaction, .groupUpdate] {
            let frame = try sized(size, envelope(sentAt: 10, recipient: "b", type: type))
            #expect(CustodyRules.admission(of: frame, now: 10, limits: limits) == .admitted(expiresAt: 10 + 86_400_000), "\(type)")
            #expect(!CustodyRules.isOversizeProfile(type: type, signedCount: size, limits: limits))
        }
    }

    @Test func aProfileOverBothCapsIsOversize() throws {
        // The byte cap comes first, so such a profile is counted once, as oversize, and the profile counter does not move.
        let tight = CustodyLimits(maxSignedBytes: 2048, maxProfileSignedBytes: 1024)
        let profile = envelope(sentAt: 10, type: .profile)
        #expect(CustodyRules.admission(of: try sized(2049, profile), now: 10, limits: tight) == .refused(.oversize))
        #expect(CustodyRules.admission(of: try sized(2048, profile), now: 10, limits: tight) == .refused(.profileOversize))
        #expect(CustodyRules.admission(of: try sized(1024, profile), now: 10, limits: tight) == .admitted(expiresAt: 10 + 86_400_000))
    }

    @Test func theProfileCapComesBeforeTheClock() throws {
        let tight = CustodyLimits(maxProfileSignedBytes: 1024)
        var dead = envelope(sentAt: 0, type: .profile)
        #expect(CustodyRules.admission(of: try sized(1025, dead), now: 1_756_200_000_000, limits: tight) == .refused(.profileOversize))
        dead.sentAt = 10 + 300_001
        #expect(CustodyRules.admission(of: try sized(1025, dead), now: 10, limits: tight) == .refused(.profileOversize))
    }

    @Test func theProfileCapDoesNotCountTheSignature() throws {
        var frame = try sized(limits.maxProfileSignedBytes, envelope(sentAt: 10, type: .profile))
        frame.sig = [UInt8](repeating: 7, count: 64)
        #expect(CustodyRules.admission(of: frame, now: 10, limits: limits) == .admitted(expiresAt: 10 + 86_400_000))
    }

    @Test func expiresAtIsComputedForARefusedFrameToo() {
        var ahead = envelope(sentAt: 10 + 300_001, recipient: "b")
        #expect(CustodyRules.expiresAt(of: ahead, limits: limits) == 10 + 300_001 + 86_400_000)
        #expect(CustodyRules.expiry(of: ahead, now: 10, limits: limits) == nil)
        ahead.recipientId = nil
        #expect(CustodyRules.expiresAt(of: ahead, limits: limits) == 10 + 300_001 + 21_600_000, "a room post's TTL")
    }
}
