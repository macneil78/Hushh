import Foundation

/// One row of the conversation: a time heading, the unread divider, a message, or an album.
public enum TimelineItem: Identifiable, Equatable, Sendable {
    /// "Today 14:20" before the first message of each day, and after an hour's quiet. `before`
    /// is the id of the message it stands above, which keeps row ids unique even when dates
    /// repeat or run backwards.
    case timestamp(Date, before: Int64)
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

    /// The first and last message the row shows; nil for headings and the divider.
    var firstMessageId: Int64? {
        switch self {
        case .message(let message, _, _): message.id
        case .album(let messages, _, _): messages.first?.id
        case .timestamp, .unreadDivider: nil
        }
    }

    var lastMessageId: Int64? {
        switch self {
        case .message(let message, _, _): message.id
        case .album(let messages, _, _): messages.last?.id
        case .timestamp, .unreadDivider: nil
        }
    }

    public var id: String {
        switch self {
        case .timestamp(_, let messageId): "time-\(messageId)"
        case .unreadDivider: "unread"
        case .message(let message, _, _): "message-\(message.id)"
        // An album's id can come back after another message interrupts it; its first message's can't.
        case .album(let messages, _, _): "album-\(messages[0].id)"
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
        rows(messages, from: 0, firstUnreadMessageId: firstUnreadMessageId, calendar: calendar)
    }

    /// Brings `items` up to date after `messages` changed from `index` on: everything before
    /// that index is as it was when `items` was built. Only the rows from the change on are built
    /// again, so a new message at the bottom costs the same however much history is loaded.
    static func update(
        _ items: inout [TimelineItem],
        messages: [MessageModel],
        changedFrom index: Int,
        firstUnreadMessageId: Int64?,
        calendar: Calendar = .current
    ) {
        // The rows just before the change can change too: an album can gain items, and a row's
        // "last in group" flag looks at the next row. So start one whole row before the row that
        // holds the message before the change.
        var start = min(index, messages.count)
        for _ in 0..<2 where start > 0 {
            start = unitStart(of: start - 1, in: messages)
        }
        guard start > 0,
              let row = items.lastIndex(where: { $0.firstMessageId == messages[start].id })
        else {
            items = build(messages, firstUnreadMessageId: firstUnreadMessageId, calendar: calendar)
            return
        }
        // The row's time heading and unread divider come before it, and are built with it.
        var cut = row
        while cut > 0, items[cut - 1].firstMessageId == nil {
            cut -= 1
        }
        items.removeSubrange(cut...)
        items += rows(messages, from: start, firstUnreadMessageId: firstUnreadMessageId, calendar: calendar)
    }

    /// Puts a changed message into its row, when nothing that groups messages changed (its date,
    /// sender, direction, album or kind). False when that's not the case or the row isn't there;
    /// then use `update`.
    static func replace(_ message: MessageModel, in items: inout [TimelineItem]) -> Bool {
        guard let index = rowIndex(of: message.id, in: items) else { return false }
        switch items[index] {
        case .message(let old, let isFirst, let isLast):
            guard old.groupsLike(message) else { return false }
            items[index] = .message(message, isFirstInGroup: isFirst, isLastInGroup: isLast)
        case .album(var album, let isFirst, let isLast):
            guard let position = album.firstIndex(where: { $0.id == message.id }), album[position].groupsLike(message) else { return false }
            album[position] = message
            items[index] = .album(album, isFirstInGroup: isFirst, isLastInGroup: isLast)
        case .timestamp, .unreadDivider:
            return false
        }
        return true
    }

    /// The rows for `messages` from `start` on, with the message before `start` as context.
    private static func rows(
        _ messages: [MessageModel],
        from start: Int,
        firstUnreadMessageId: Int64?,
        calendar: Calendar
    ) -> [TimelineItem] {
        // First gather album items: consecutive messages with the same album id.
        var units: [[MessageModel]] = []
        for message in messages[start...] {
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
            let previous = index > 0 ? units[index - 1].last : (start > 0 ? messages[start - 1] : nil)
            let next = index + 1 < units.count ? units[index + 1] : nil

            let startsBurst = previous.map {
                !calendar.isDate($0.date, inSameDayAs: first.date) || first.date.timeIntervalSince($0.date) >= headingInterval
            } ?? true
            if startsBurst {
                items.append(.timestamp(first.date, before: first.id))
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

    /// Where the album holding `messages[index]` starts (`index` itself when it's no album).
    private static func unitStart(of index: Int, in messages: [MessageModel]) -> Int {
        var start = index
        let albumId = messages[index].albumId
        while albumId != 0, start > 0, messages[start - 1].albumId == albumId {
            start -= 1
        }
        return start
    }

    /// The row that shows the message, found by halving: rows are in message id order.
    private static func rowIndex(of messageId: Int64, in items: [TimelineItem]) -> Int? {
        var low = 0
        var high = items.count
        while low < high {
            let middle = (low + high) / 2
            // Headings and the divider show no message: look at the row they stand above.
            var probe = middle
            while probe < high, items[probe].firstMessageId == nil {
                probe += 1
            }
            guard probe < high, let first = items[probe].firstMessageId, let last = items[probe].lastMessageId else {
                high = middle
                continue
            }
            if messageId < first {
                high = middle
            } else if messageId > last {
                low = probe + 1
            } else {
                return probe
            }
        }
        return nil
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

extension MessageModel {
    /// Whether the two group with their neighbours alike: same date, sender, direction, album
    /// and kind. A change in anything else (text, reactions, status) leaves the rows as they are.
    func groupsLike(_ other: MessageModel) -> Bool {
        id == other.id && date == other.date && isOutgoing == other.isOutgoing && sender.id == other.sender.id
            && albumId == other.albumId && isService == other.isService
    }
}
