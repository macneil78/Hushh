import Foundation
import Testing
@testable import HushCore
@testable import HushUI

/// The day headings in a conversation: Today, Yesterday, a weekday, or a date.
struct DayHeadingTests {
    private let calendar = Calendar.current

    /// Friday 13 November 2026, 15:00 on this Mac's clock.
    private var friday: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 15))!
    }

    private func daysBefore(_ days: Int, hour: Int) -> Date {
        let day = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: friday))!
        return calendar.date(byAdding: .hour, value: hour, to: day)!
    }

    @Test func lastWeeksSameWeekdayGetsItsDate() {
        let lastFriday = daysBefore(7, hour: 10)
        #expect(DayHeading.label(for: lastFriday, now: friday) == lastFriday.formatted(.dateTime.weekday(.wide).day().month(.wide)))
    }

    @Test func theDaysOfThePastWeekGetTheirWeekday() {
        #expect(DayHeading.label(for: daysBefore(0, hour: 9), now: friday) == "Today")
        #expect(DayHeading.label(for: daysBefore(1, hour: 23), now: friday) == "Yesterday")
        let saturday = daysBefore(6, hour: 23)
        #expect(DayHeading.label(for: saturday, now: friday) == saturday.formatted(.dateTime.weekday(.wide)))
    }

    @Test func datesAheadGetTheirDate() {
        let tomorrow = daysBefore(-1, hour: 9)
        #expect(DayHeading.label(for: tomorrow, now: friday) == tomorrow.formatted(.dateTime.weekday(.wide).day().month(.wide)))
        let nextYear = daysBefore(-400, hour: 9)
        #expect(DayHeading.label(for: nextYear, now: friday) == nextYear.formatted(date: .long, time: .omitted))
    }
}
