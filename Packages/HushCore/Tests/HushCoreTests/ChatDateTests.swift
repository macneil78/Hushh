import Foundation
import Testing
@testable import HushCore
@testable import HushUI

/// The sidebar's date and the "last seen" text, at the edges of days and years.
struct ChatDateTests {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func time(_ date: Date, _ calendar: Calendar) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone))
    }

    private func weekday(_ date: Date, _ calendar: Calendar) -> String {
        date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated))
    }

    /// The row passes the time it redraws at; a message from the real today, read three days
    /// later, is no longer "today".
    @Test func usesTheGivenNow() {
        let today = Date()
        let later = Calendar.current.date(byAdding: .day, value: 3, to: today)!
        #expect(ChatDate.short(today, now: later) == weekday(today, .current))
    }

    /// Five minutes after midnight, a message from 23:50 is yesterday's.
    @Test func midnightTurnsATimeIntoAWeekday() {
        let midnight = Date(timeIntervalSince1970: 1_791_590_400)  // 10 Oct 2026 00:00 UTC
        let beforeMidnight = midnight - 10 * 60
        #expect(ChatDate.short(beforeMidnight, now: midnight - 60, calendar: utc) == time(beforeMidnight, utc))
        #expect(ChatDate.short(beforeMidnight, now: midnight + 5 * 60, calendar: utc) == weekday(beforeMidnight, utc))
    }

    /// A message dated a little ahead of this Mac's clock reads as today, not as last week.
    @Test func dateAheadOfTheClockShowsItsTime() {
        let now = Date(timeIntervalSince1970: 1_791_558_000)  // 9 Oct 2026 15:00 UTC
        let tomorrow = now + 20 * 3600
        #expect(ChatDate.short(tomorrow, now: now, calendar: utc) == time(tomorrow, utc))
    }

    /// Seen on 31 Dec at 20:00, read on 2 Jan: the day and time, as within one year.
    @Test func lastSeenAcrossNewYearKeepsTheTime() {
        let now = Date(timeIntervalSince1970: 1_798_884_000)   // 2 Jan 2027 10:00 UTC
        let seen = Date(timeIntervalSince1970: 1_798_747_200)  // 31 Dec 2026 20:00 UTC
        let text = Presence.lastSeen(seen).text(now: now, calendar: utc)
        #expect(text.hasSuffix(" at \(time(seen, utc))"), "got '\(text)'")
        let longAgo = Presence.lastSeen(now - 300 * 86400).text(now: now, calendar: utc)
        #expect(!longAgo.contains(" at "), "got '\(longAgo)'")
    }
}
