import Foundation

/// One row of the conversation: a time heading, the unread divider, a message, or an album.
public enum TimelineItem: Identifiable, Equatable, Sendable {
    /// "Today 14:20" before the first message of each day, and after an hour's quiet.
    case timestamp(Date)
    case unreadDivider
    /// Consecutive messages from one sender within a few minutes form a group: only the first
    /// shows the sender's name, only the last shows their picture.
    case message(MessageModel, isFirstInGroup: Bool, isLastInGroup: Bool)
    /// Photos, videos or files sent together, shown as one bubble.
    case album([MessageModel], isFirstInGroup: Bool, isLastInGroup: Bool)

    /// Whether this row shows the message (on its own, or in an album).
    public func contains(messageId: Int64) -> Bool {
        switch self {
        case .message(let message, _, _): message.id == messageId
        case .album(let messages, _, _): messages.contains { $0.id == messageId }
        case .timestamp, .unreadDivider: false
        }
    }

    public var id: String {
        switch self {
        case .timestamp(let date): "time-\(Int(date.timeIntervalSince1970))"
        case .unreadDivider: "unread"
        case .message(let message, _, _): "message-\(message.id)"
        case .album(let messages, _, _): "album-\(messages[0].albumId)"
        }
    }
}

public enum Timeline {
    /// How far apart two messages can be and still group together.
    static let groupingInterval: TimeInterval = 5 * 60
    /// The quiet after which a new time heading appears, as in Messages.
    static let headingInterval: TimeInterval = 60 * 60

    public static func build(
        _ messages: [MessageModel],
        firstUnreadMessageId: Int64?,
        calendar: Calendar = .current
    ) -> [TimelineItem] {
        // First gather album items: consecutive messages with the same album id.
        var units: [[MessageModel]] = []
        for message in messages {
            if message.albumId != 0, let last = units.last?.last, last.albumId == message.albumId {
                units[units.count - 1].append(message)
            } else {
                units.append([message])
            }
        }
        func containsUnread(_ unit: [MessageModel]) -> Bool {
            unit.contains { $0.id == firstUnreadMessageId }
        }

        var items: [TimelineItem] = []
        items.reserveCapacity(units.count + 8)
        for (index, unit) in units.enumerated() {
            let first = unit[0]
            let last = unit[unit.count - 1]
            let previous = index > 0 ? units[index - 1].last : nil
            let next = index + 1 < units.count ? units[index + 1] : nil

            let startsBurst = previous.map {
                !calendar.isDate($0.date, inSameDayAs: first.date) || first.date.timeIntervalSince($0.date) >= headingInterval
            } ?? true
            if startsBurst {
                items.append(.timestamp(first.date))
            }
            let startsUnread = containsUnread(unit)
            if startsUnread {
                items.append(.unreadDivider)
            }

            let isFirst = startsBurst || startsUnread || !continues(previous, first, calendar: calendar)
            let isLast = next.map { containsUnread($0) || !continues(last, $0[0], calendar: calendar) } ?? true
            if unit.count > 1 {
                items.append(.album(unit, isFirstInGroup: isFirst, isLastInGroup: isLast))
            } else {
                items.append(.message(first, isFirstInGroup: isFirst, isLastInGroup: isLast))
            }
        }
        return items
    }

    private static func continues(_ earlier: MessageModel?, _ later: MessageModel, calendar: Calendar) -> Bool {
        guard let earlier else { return false }
        return !earlier.isService && !later.isService
            && earlier.isOutgoing == later.isOutgoing
            && earlier.sender.id == later.sender.id
            && later.date.timeIntervalSince(earlier.date) < groupingInterval
            && calendar.isDate(earlier.date, inSameDayAs: later.date)
    }
}
