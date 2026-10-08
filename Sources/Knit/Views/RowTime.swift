#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// When a row's newest message was sent, as briefly as Signal's list says it: "Now", "7m", "9:30 AM", "Tue", "Oct 3"
    /// (``RowAge``). Read against the clock every minute, not once at render, so it keeps counting while the list stays
    /// open, as Android's does (ChatListScreen.kt's rememberCurrentTimeMillis). VoiceOver hears minutes in full.
    internal struct RowTime: View {
        private static let secondsPerMinute = 60

        let sent: Date

        var body: some View {
            TimelineView(.everyMinute) { context in
                let age = RowAge(sent: sent, now: context.date, calendar: .current)
                Text(written(age))
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .accessibilityLabel(spoken(age))
            }
        }

        private func written(_ age: RowAge) -> String {
            switch age {
            case .now:
                Copy.ChatList.justNow
            case .minutes(let minutes):
                Duration.seconds(minutes * Self.secondsPerMinute).formatted(.units(allowed: [.minutes], width: .narrow))
            case .today:
                sent.formatted(date: .omitted, time: .shortened)
            case .thisWeek:
                sent.formatted(.dateTime.weekday(.abbreviated))
            case .thisYear:
                sent.formatted(.dateTime.month(.abbreviated).day())
            case .older:
                sent.formatted(date: .numeric, time: .omitted)
            }
        }

        private func spoken(_ age: RowAge) -> String {
            switch age {
            case .minutes:
                sent.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
            case .thisWeek:
                sent.formatted(.dateTime.weekday(.wide))
            case .now, .today, .thisYear, .older:
                written(age)
            }
        }
    }
#endif
