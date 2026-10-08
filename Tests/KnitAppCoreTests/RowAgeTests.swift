import Foundation
import Testing

@testable import KnitAppCore

/// The chat list's compact times: each step Signal's list shows, at its edges.
@Suite struct RowAgeTests {
    private let calendar: Calendar = {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return gregorian
    }()

    /// Wednesday 7 October 2026, 15:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_791_385_200)

    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 86_400

    private func age(_ secondsAgo: TimeInterval) -> RowAge {
        RowAge(sent: now.addingTimeInterval(-secondsAgo), now: now, calendar: calendar)
    }

    @Test func underAMinuteAndAheadOfOurClockAreNow() {
        #expect(age(0) == .now)
        #expect(age(59) == .now)
        #expect(age(-300) == .now)
    }

    @Test func withinTheHourCountsWholeMinutes() {
        #expect(age(60) == .minutes(1))
        #expect(age(7 * 60 + 30) == .minutes(7))
        #expect(age(hour - 1) == .minutes(59))
    }

    @Test func earlierTodayShowsTheTime() {
        #expect(age(hour) == .today)
        #expect(age(15 * hour) == .today)
    }

    @Test func theRestOfTheWeekShowsTheWeekday() {
        #expect(age(15 * hour + 1) == .thisWeek)
        #expect(age(6 * day) == .thisWeek)
        #expect(age(7 * day) == .thisYear)
    }

    @Test func anotherYearShowsTheYear() {
        #expect(age(300 * day) == .older)
    }
}
