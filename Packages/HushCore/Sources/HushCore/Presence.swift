import Foundation

/// When someone was last online, as far as their Telegram privacy settings share it.
public enum Presence: Equatable, Sendable {
    case online(until: Date)
    case lastSeen(Date)
    case recently
    case withinWeek
    case withinMonth
    case longAgo
    case bot

    public func isOnline(at now: Date = .now) -> Bool {
        if case .online(let until) = self { return until > now }
        return false
    }

    /// "online", "last seen 5 minutes ago", "last seen today at 14:20", "last seen recently"…
    public func text(now: Date = .now, calendar: Calendar = .current) -> String {
        switch self {
        case .online(let until):
            // Telegram's "online" lapses at `until` unless renewed.
            return until > now ? "online" : Presence.lastSeen(until).text(now: now, calendar: calendar)
        case .lastSeen(let date):
            let seconds = now.timeIntervalSince(date)
            if seconds < 60 { return "last seen just now" }
            if seconds < 3600 {
                let minutes = Int(seconds / 60)
                return "last seen \(minutes) minute\(minutes == 1 ? "" : "s") ago"
            }
            let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone))
            if calendar.isDate(date, inSameDayAs: now) { return "last seen today at \(time)" }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
                return "last seen yesterday at \(time)"
            }
            if calendar.isDate(date, equalTo: now, toGranularity: .year) {
                let day = date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).day().month(.abbreviated))
                return "last seen \(day) at \(time)"
            }
            return "last seen \(date.formatted(Date.FormatStyle(date: .numeric, time: .omitted, calendar: calendar, timeZone: calendar.timeZone)))"
        case .recently:
            return "last seen recently"
        case .withinWeek:
            return "last seen within a week"
        case .withinMonth:
            return "last seen within a month"
        case .longAgo:
            return "last seen a long time ago"
        case .bot:
            return "bot"
        }
    }
}
