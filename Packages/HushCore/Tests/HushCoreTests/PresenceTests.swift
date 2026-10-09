import Foundation
import Testing
@testable import HushCore

struct PresenceTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// 9 October 2026, 15:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_791_558_000)

    private func text(_ presence: Presence) -> String {
        presence.text(now: now, calendar: calendar)
    }

    @Test func onlineUntilItLapses() {
        #expect(text(.online(until: now + 120)) == "online")
        #expect(Presence.online(until: now + 120).isOnline(at: now))
        #expect(text(.online(until: now - 300)) == "last seen 5 minutes ago")
        #expect(!Presence.online(until: now - 1).isOnline(at: now))
    }

    @Test func lastSeenReadsNaturally() {
        #expect(text(.lastSeen(now - 20)) == "last seen just now")
        #expect(text(.lastSeen(now - 60)) == "last seen 1 minute ago")
        #expect(text(.lastSeen(now - 2 * 3600)).hasPrefix("last seen today at"))
        #expect(text(.lastSeen(now - 20 * 3600)).hasPrefix("last seen yesterday at"))
        #expect(text(.lastSeen(now - 30 * 86400)).hasPrefix("last seen 9 Sep at") || text(.lastSeen(now - 30 * 86400)).hasPrefix("last seen Sep 9 at"))
    }

    @Test func privacyLimitedStatuses() {
        #expect(text(.recently) == "last seen recently")
        #expect(text(.withinWeek) == "last seen within a week")
        #expect(text(.longAgo) == "last seen a long time ago")
    }
}
