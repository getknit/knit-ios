public import Foundation

/// How long ago a chat list row's newest message was sent, in the steps Signal's list shows it: "Now", minutes within the
/// hour ("7m"), the time earlier today, the weekday within the week, then the date. The view formats each step; this
/// only picks it, so the steps are tested here on Linux.
public enum RowAge: Sendable, Equatable {
    /// Under a minute ago, or stamped ahead of our clock by the author's.
    case now
    /// This many whole minutes ago, within the hour.
    case minutes(Int)
    /// Earlier today, over an hour ago: the time.
    case today
    /// Within the past six days, before today: the weekday.
    case thisWeek
    /// Earlier this year: the month and day.
    case thisYear
    /// Before this year: the date with its year.
    case older

    private static let minute: TimeInterval = 60
    private static let hour: TimeInterval = 3600
    /// The days before today that still show a weekday: a seventh back would name today's weekday again.
    private static let weekdayDays = 6

    /// The step for a message sent at `sent`, seen at `now` on `calendar`.
    public init(sent: Date, now: Date, calendar: Calendar) {
        let seconds = now.timeIntervalSince(sent)
        let weekAgo = calendar.date(byAdding: .day, value: -Self.weekdayDays, to: calendar.startOfDay(for: now)) ?? now
        if seconds < Self.minute {
            self = .now
        } else if seconds < Self.hour {
            self = .minutes(Int(seconds / Self.minute))
        } else if calendar.isDate(sent, inSameDayAs: now) {
            self = .today
        } else if sent >= weekAgo {
            self = .thisWeek
        } else if calendar.isDate(sent, equalTo: now, toGranularity: .year) {
            self = .thisYear
        } else {
            self = .older
        }
    }
}
