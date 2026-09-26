import KnitStore
import KnitWire
import Testing

/// The pure custody rules every store applies.
@Suite struct CustodyRulesTests {
    private let limits = CustodyLimits()

    private func envelope(sentAt: Int64, recipient: String? = nil, type: FrameType = .chat) -> RelayEnvelope {
        RelayEnvelope(type: type, id: "m1", senderId: "a", sentAt: sentAt, recipientId: recipient, payload: [])
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
}
