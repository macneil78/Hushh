import Foundation
import Testing
@preconcurrency import TDLibKit
@testable import HushCore
@testable import HushUI

@MainActor
struct SharedMediaTests {
    private func message(_ id: Int64, _ body: MessageModel.Body, at date: Foundation.Date = .now) -> MessageModel {
        MessageModel(
            id: id,
            date: date,
            isOutgoing: false,
            sender: .init(id: 2, name: "Anna", accentColorId: 0, photoFileId: nil),
            body: body,
            replyToMessageId: nil,
            reply: nil,
            forwardedFrom: nil,
            isEdited: false,
            status: .sent
        )
    }

    @Test func eachTabSearchesItsKind() {
        #expect(SharedMediaKind.media.filter == .searchMessagesFilterPhotoAndVideo)
        #expect(SharedMediaKind.files.filter == .searchMessagesFilterDocument)
        #expect(SharedMediaKind.links.filter == .searchMessagesFilterUrl)
        #expect(SharedMediaKind.voice.filter == .searchMessagesFilterVoiceNote)
        #expect(SharedMediaKind.music.filter == .searchMessagesFilterAudio)
        #expect(SharedMediaKind.media.countText(1) == "1 photo or video")
        #expect(SharedMediaKind.voice.countText(12) == "12 voice messages")
    }

    @Test func linksComeFromTheTextInOrderWithoutRepeats() {
        let site = URL(string: "https://example.com/a")!
        let other = URL(string: "https://swift.org")!
        let text = RichText(text: "see example.com/a and swift.org, again example.com/a", spans: [
            .init(range: 4..<17, style: .link(site)),
            .init(range: 22..<31, style: .link(other)),
            .init(range: 39..<52, style: .link(site)),
        ])
        #expect(message(1, .text(text)).links == [site, other])
        #expect(message(2, .text(RichText(text: "no links here"))).links.isEmpty)
    }

    @Test func listsGroupByMonthNewestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let october = Foundation.Date(timeIntervalSince1970: 1_791_558_000)  // 9 Oct 2026
        let items = [
            message(3, .text(RichText(text: "c")), at: october),
            message(2, .text(RichText(text: "b")), at: october - 3 * 86400),
            message(1, .text(RichText(text: "a")), at: october - 40 * 86400),  // late August
        ]
        let months = ChatDetailsView.months(items, calendar: calendar)
        #expect(months.map { $0.items.map(\.id) } == [[3, 2], [1]])
    }

    @Test func linkRowsNameTheSite() {
        #expect(LinkRow.site(of: URL(string: "https://www.github.com/tdlib/td")) == "github.com")
        #expect(LinkRow.site(of: URL(string: "https://t.me/hushh")) == "t.me")
        #expect(LinkRow.site(of: nil) == "Link")
    }
}
