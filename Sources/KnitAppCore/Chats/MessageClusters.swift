public import Foundation

/// Where a message sits among its neighbors in a thread (ADR 2026-10.5waw). Signal draws a run of messages from one
/// author, sent close together, as a cluster: tight corners where the bubbles join, the author's name over the first and
/// their face beside the last. It writes the time and the tick once under a run that shares them, and dates each day.
public struct MessagePlace: Sendable, Equatable {
    /// Whether the message before it is in its cluster.
    public var joinsPrevious = false
    /// Whether the message after it is in its cluster.
    public var joinsNext = false
    /// Whether its time, and its tick when it is ours, show under it: the next message's would say something else.
    public var showsStamp = true
    /// Whether it is the first of its day in the thread, and so sits under that day's date.
    public var startsDay = false
}

/// Folds a thread's messages into their places. Pure over its inputs, so the rules are tested without a view.
public enum MessageClusters {
    /// How far apart two messages from one author may be sent and still join, in milliseconds: three minutes.
    static let window: Int64 = 180_000
    /// How long a minute is, in milliseconds: a stamp shows a time to the minute.
    static let minute: Int64 = 60_000

    /// The place of each of `messages`, in order, with its days as `calendar` divides them.
    public static func places(_ messages: [ChatMessage], calendar: Calendar) -> [MessagePlace] {
        var places = Array(repeating: MessagePlace(), count: messages.count)
        for index in messages.indices {
            let message = messages[index]
            let previous = index > 0 ? messages[index - 1] : nil
            places[index].startsDay = previous.map { !sameDay($0, message, calendar: calendar) } ?? true
            if let previous, joins(previous, message, calendar: calendar) {
                places[index].joinsPrevious = true
                places[index - 1].joinsNext = true
                places[index - 1].showsStamp = !sharesStamp(previous, message)
            }
        }
        return places
    }

    /// Whether `next` joins `message`'s cluster: the same author, on the same day, soon after, and neither a status line.
    static func joins(_ message: ChatMessage, _ next: ChatMessage, calendar: Calendar) -> Bool {
        message.notice == nil && next.notice == nil && message.isMine == next.isMine && message.author == next.author
            && abs(next.sentAt - message.sentAt) <= window && sameDay(message, next, calendar: calendar)
    }

    /// Whether one stamp says it for both: the same minute, and the same tick.
    static func sharesStamp(_ message: ChatMessage, _ next: ChatMessage) -> Bool {
        message.sentAt / minute == next.sentAt / minute && message.status == next.status
    }

    private static func sameDay(_ first: ChatMessage, _ second: ChatMessage, calendar: Calendar) -> Bool {
        calendar.isDate(Date(milliseconds: first.sentAt), inSameDayAs: Date(milliseconds: second.sentAt))
    }
}

extension Date {
    private static let millisecondsPerSecond = 1000.0

    /// A mesh timestamp, in milliseconds since the epoch.
    public init(milliseconds: Int64) {
        self.init(timeIntervalSince1970: Double(milliseconds) / Self.millisecondsPerSecond)
    }
}
