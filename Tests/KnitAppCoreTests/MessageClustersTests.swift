import Foundation
import KnitWire
import Testing

@testable import KnitAppCore

/// How a thread's messages cluster, where their stamps show, and where each day starts (ADR 2026-10.5waw).
@MainActor
@Suite struct MessageClustersTests {
    /// A calendar on UTC, so a day's edge is the same wherever the test runs.
    private static let calendar: Calendar = {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? utc.timeZone
        return utc
    }()

    /// 2026-10-04 at 12:00 UTC, in milliseconds.
    private static let noon: Int64 = 1_791_115_200_000
    private static let second: Int64 = 1000
    private static let minute: Int64 = 60 * second

    @Test func oneAuthorsRunJoinsAndStampsOnceAtItsEnd() {
        let places = Self.places([
            Self.message("a", at: Self.noon, by: AppRig.sam.nodeId),
            Self.message("b", at: Self.noon + 10 * Self.second, by: AppRig.sam.nodeId),
            Self.message("c", at: Self.noon + 20 * Self.second, by: AppRig.sam.nodeId),
        ])
        #expect(places.map(\.joinsPrevious) == [false, true, true])
        #expect(places.map(\.joinsNext) == [true, true, false])
        #expect(places.map(\.showsStamp) == [false, false, true])
        #expect(places.map(\.startsDay) == [true, false, false])
    }

    @Test func anotherAuthorOrOurOwnMessageStartsAnotherCluster() {
        let places = Self.places([
            Self.message("a", at: Self.noon, by: AppRig.sam.nodeId),
            Self.message("b", at: Self.noon + Self.second, by: AppRig.priya.nodeId),
            Self.message("c", at: Self.noon + 2 * Self.second, by: AppRig.priya.nodeId, mine: true, status: .sent),
        ])
        #expect(places.map(\.joinsNext) == [false, false, false])
        let stamped = places.allSatisfy(\.showsStamp)
        #expect(stamped)
    }

    @Test func aPauseLongerThanTheWindowBreaksTheRun() {
        let places = Self.places([
            Self.message("a", at: Self.noon, by: AppRig.sam.nodeId),
            Self.message("b", at: Self.noon + MessageClusters.window, by: AppRig.sam.nodeId),
            Self.message("c", at: Self.noon + 2 * MessageClusters.window + Self.second, by: AppRig.sam.nodeId),
        ])
        #expect(places.map(\.joinsNext) == [true, false, false])
        // Three minutes apart, the first keeps its own stamp: one time would not say both.
        #expect(places.map(\.showsStamp) == [true, true, true])
    }

    @Test func ourRunStampsAgainWhereTheTickChanges() {
        let me = AppRig.sam.nodeId
        let places = Self.places([
            Self.message("a", at: Self.noon, by: me, mine: true, status: .delivered),
            Self.message("b", at: Self.noon + Self.second, by: me, mine: true, status: .sent),
            Self.message("c", at: Self.noon + 2 * Self.second, by: me, mine: true, status: .sent),
        ])
        #expect(places.map(\.joinsNext) == [true, true, false])
        #expect(places.map(\.showsStamp) == [true, false, true])
    }

    @Test func aStatusLineJoinsNothing() {
        var notice = Self.message("n", at: Self.noon + Self.second, by: AppRig.sam.nodeId)
        notice.notice = "Sam left"
        let places = Self.places([
            Self.message("a", at: Self.noon, by: AppRig.sam.nodeId),
            notice,
            Self.message("b", at: Self.noon + 2 * Self.second, by: AppRig.sam.nodeId),
        ])
        #expect(places.map(\.joinsNext) == [false, false, false])
        #expect(places.map(\.joinsPrevious) == [false, false, false])
    }

    @Test func midnightStartsADayAndBreaksTheRun() {
        let midnight = Self.noon + 12 * 60 * Self.minute
        let places = Self.places([
            Self.message("a", at: midnight - Self.second, by: AppRig.sam.nodeId),
            Self.message("b", at: midnight, by: AppRig.sam.nodeId),
        ])
        #expect(places.map(\.startsDay) == [true, true])
        #expect(places.map(\.joinsNext) == [false, false])
    }

    @Test func anEmptyThreadHasNoPlaces() {
        #expect(Self.places([]).isEmpty)
    }

    @Test func aTimestampIsMillisecondsSinceTheEpoch() {
        #expect(Date(milliseconds: 1500) == Date(timeIntervalSince1970: 1.5))
    }

    private static func places(_ messages: [ChatMessage]) -> [MessagePlace] {
        MessageClusters.places(messages, calendar: calendar)
    }

    private static func message(
        _ id: String, at sentAt: Int64, by author: NodeId, mine: Bool = false, status: DeliveryStatus? = nil
    ) -> ChatMessage {
        ChatMessage(id: id, body: id, sentAt: sentAt, isMine: mine, author: author, status: status)
    }
}
