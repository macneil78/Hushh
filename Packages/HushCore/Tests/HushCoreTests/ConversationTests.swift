import Foundation
import Testing
@preconcurrency import TDLibKit
@testable import HushCore
@testable import HushUI

struct RichTextTests {
    @Test func entitiesUseUTF16Offsets() {
        // "👋" is two UTF-16 code units, so "bold" starts at offset 3, not 2.
        let formatted = FormattedText(
            entities: [
                TextEntity(length: 4, offset: 3, type: .textEntityTypeBold),
                TextEntity(length: 9, offset: 12, type: .textEntityTypeUrl),
            ],
            text: "👋 bold and x.com/abc"
        )
        let rich = RichText(formatted)
        #expect(rich.spans.first == RichText.Span(range: 3..<7, style: .bold))
        #expect(RichText.substring(of: rich.text, utf16: 3..<7) == "bold")
        // Bare links get a scheme so they open in the browser.
        #expect(rich.spans.last?.style == .link(URL(string: "https://x.com/abc")!))
    }

    @Test func customEmojiAreLeftAsPlainEmoji() {
        let formatted = FormattedText(
            entities: [TextEntity(length: 2, offset: 0, type: .textEntityTypeCustomEmoji(.init(customEmojiId: 1)))],
            text: "🔥"
        )
        #expect(RichText(formatted).spans.isEmpty)
    }
}

struct TimelineTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func message(_ id: Int64, from senderId: Int64, at date: Foundation.Date, outgoing: Bool = false, service: Bool = false, album: Int64 = 0) -> MessageModel {
        MessageModel(
            id: id,
            date: date,
            isOutgoing: outgoing,
            sender: .init(id: senderId, name: "User \(senderId)", accentColorId: 0, photoFileId: nil),
            body: service ? .service("Alex joined the group") : .text(RichText(text: "hi")),
            replyToMessageId: nil,
            reply: nil,
            forwardedFrom: nil,
            isEdited: false,
            status: .sent,
            albumId: album
        )
    }

    private func groups(_ items: [TimelineItem]) -> [String] {
        items.map { item in
            switch item {
            case .timestamp: "time"
            case .unreadDivider: "unread"
            case .message(let message, let first, let last): "\(message.id)\(first ? "F" : "")\(last ? "L" : "")"
            case .album(let messages, let first, let last):
                "[\(messages.map { String($0.id) }.joined(separator: ","))]\(first ? "F" : "")\(last ? "L" : "")"
            }
        }
    }

    @Test func groupsConsecutiveMessagesFromOneSender() {
        let start = Foundation.Date(timeIntervalSince1970: 1_760_000_000)
        let items = Timeline.build([
            message(1, from: 7, at: start),
            message(2, from: 7, at: start + 60),
            message(3, from: 8, at: start + 120),
            message(4, from: 8, at: start + 120 + 600),  // ten minutes later: new group
        ], firstUnreadMessageId: nil, calendar: calendar)
        #expect(groups(items) == ["time", "1F", "2L", "3FL", "4FL"])
    }

    @Test func dayHeadingsAndUnreadDividerBreakGroups() {
        let lateEvening = Foundation.Date(timeIntervalSince1970: 1_760_054_000)  // 23:53 UTC
        let items = Timeline.build([
            message(1, from: 7, at: lateEvening),
            message(2, from: 7, at: lateEvening + 60),
            message(3, from: 7, at: lateEvening + 600),  // after midnight
            message(4, from: 7, at: lateEvening + 660),
        ], firstUnreadMessageId: 4, calendar: calendar)
        #expect(groups(items) == ["time", "1F", "2L", "time", "3FL", "unread", "4FL"])
    }

    @Test func anHoursQuietBringsANewTimeHeading() {
        let start = Foundation.Date(timeIntervalSince1970: 1_760_000_000)
        let items = Timeline.build([
            message(1, from: 7, at: start),
            message(2, from: 8, at: start + 59 * 60),
            message(3, from: 8, at: start + 59 * 60 + 3600),  // an hour later
        ], firstUnreadMessageId: nil, calendar: calendar)
        #expect(groups(items) == ["time", "1FL", "2FL", "time", "3FL"])
    }

    @Test func albumsBecomeOneItemThatStillGroups() {
        let start = Foundation.Date(timeIntervalSince1970: 1_760_000_000)
        let items = Timeline.build([
            message(1, from: 7, at: start),
            message(2, from: 7, at: start + 30, album: 99),
            message(3, from: 7, at: start + 30, album: 99),
            message(4, from: 7, at: start + 30, album: 99),
            message(5, from: 7, at: start + 60),
        ], firstUnreadMessageId: nil, calendar: calendar)
        #expect(groups(items) == ["time", "1F", "[2,3,4]", "5L"])
    }

    @Test func unreadInsideAnAlbumPutsTheDividerAboveIt() {
        let start = Foundation.Date(timeIntervalSince1970: 1_760_000_000)
        let items = Timeline.build([
            message(1, from: 7, at: start),
            message(2, from: 7, at: start + 30, album: 99),
            message(3, from: 7, at: start + 30, album: 99),
        ], firstUnreadMessageId: 3, calendar: calendar)
        #expect(groups(items) == ["time", "1FL", "unread", "[2,3]FL"])
    }

    @Test func serviceMessagesStandAlone() {
        let start = Foundation.Date(timeIntervalSince1970: 1_760_000_000)
        let items = Timeline.build([
            message(1, from: 7, at: start),
            message(2, from: 7, at: start + 10, service: true),
            message(3, from: 7, at: start + 20),
        ], firstUnreadMessageId: nil, calendar: calendar)
        #expect(groups(items) == ["time", "1FL", "2FL", "3FL"])
    }
}

struct MessageMapperTests {
    private func body(_ content: MessageContent, senderId: Int64 = 7, outgoing: Bool = false) -> MessageModel.Body? {
        MessageMapper.body(
            for: content,
            isOutgoing: outgoing,
            senderId: senderId,
            senderName: outgoing ? "You" : "Alex",
            name: { $0 == 8 ? "Sam" : "Kim" }
        )
    }

    @Test func joiningAndAdding() {
        #expect(body(.messageChatAddMembers(.init(memberUserIds: [7]))) == .service("Alex joined the group"))
        #expect(body(.messageChatAddMembers(.init(memberUserIds: [8, 9]))) == .service("Alex added Sam and Kim"))
        #expect(body(.messageChatDeleteMember(.init(userId: 7))) == .service("Alex left the group"))
    }

    @Test func paymentsAndMiniAppPlumbingAreHidden() {
        #expect(body(.messageWebAppDataSent(.init(buttonText: "Open"))) == nil)
        #expect(body(.messageCustomServiceAction(.init(text: "Alex set a new wallpaper"))) == .service("Alex set a new wallpaper"))
    }

    @Test func noiseIsHiddenAndStoriesArePlaceholders() {
        #expect(body(.messageChatUpgradeFrom(.init(basicGroupId: 1, title: "Old"))) == nil)
        #expect(body(.messageContactRegistered) == .service("Alex joined Telegram"))
        if case .placeholder = body(.messageUnsupported) {} else { Issue.record("Unsupported content should be a placeholder") }
    }
}

struct ReactionEmojiTests {
    @Test func bareSymbolsGetTheirColorfulForm() {
        #expect(Emoji.colorful("\u{2764}") == "\u{2764}\u{FE0F}")  // ❤ → ❤️
        #expect(Emoji.colorful("\u{2764}\u{200D}\u{1F525}") == "\u{2764}\u{FE0F}\u{200D}\u{1F525}")  // heart on fire
        #expect(Emoji.colorful("\u{263A}") == "\u{263A}\u{FE0F}")  // ☺
    }

    @Test func emojiThatAreAlreadyColorfulStayAsTheyAre() {
        for emoji in ["\u{2764}\u{FE0F}", "👍", "🔥", "🥰", "👍🏽", "🤷‍♂️"] {
            #expect(Emoji.colorful(emoji) == emoji)
        }
    }
}
