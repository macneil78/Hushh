import Foundation
import Testing
@preconcurrency import TDLibKit
@testable import HushAI
@testable import HushCore
@testable import HushUI

/// Spoilers stay hidden everywhere text shows outside its bubble: the chat list, notification
/// banners, reply quotes, search results and the Links tab.
@MainActor
struct SpoilerTests {
    private let secret = FormattedText(
        entities: [TextEntity(length: 4, offset: 8, type: .textEntityTypeSpoiler)],
        text: "My PIN: 4417, don't tell"
    )
    private let masked = "My PIN: ▒▒▒▒, don't tell"

    private func message(_ body: MessageModel.Body) -> MessageModel {
        MessageModel(
            id: 1, date: .now, isOutgoing: false, sender: .init(id: 2, name: "Anna", accentColorId: 0, photoFileId: nil),
            body: body, replyToMessageId: nil, reply: nil, forwardedFrom: nil, isEdited: false, status: .sent
        )
    }

    private func photo(caption: FormattedText, isSecret: Bool = false) -> MessageContent {
        .messagePhoto(MessagePhoto(
            caption: caption, hasSpoiler: false, isSecret: isSecret,
            photo: Photo(hasStickers: false, minithumbnail: nil, sizes: []), showCaptionAboveMedia: false, video: nil
        ))
    }

    @Test func chatListAndNotificationTextMaskSpoilers() {
        let text = MessagePreview.text(for: .messageText(MessageText(linkPreview: nil, linkPreviewOptions: nil, text: secret)))
        #expect(text == masked)
        #expect(MessagePreview.text(for: photo(caption: secret)) == "Photo: \(masked)")
        // The banner's body is this same text.
        let banner = NotificationService.content(chatTitle: "Alex", senderName: nil, preview: text, isSilent: true, chatId: 1, messageId: 1)
        #expect(!banner.body.contains("4417"))
    }

    /// A self-destructing photo shows only its kind, never its caption, as in the timeline.
    @Test func selfDestructingMediaShowsOnlyItsKind() {
        #expect(MessagePreview.text(for: photo(caption: FormattedText(entities: [], text: "for your eyes"), isSecret: true)) == "Self-destructing photo")
        #expect(MessagePreview.text(for: photo(caption: FormattedText(entities: [], text: "for your eyes")), selfDestructs: true) == "Self-destructing photo")
    }

    @Test func replyQuotesSearchAndLinksMaskSpoilers() {
        let text = message(.text(HushCore.RichText(secret)))
        #expect(text.previewText == masked)
        #expect(text.textHidingSpoilers == masked)
        // Copy still copies what the message says.
        #expect(text.plainText == secret.text)
        let caption = message(.photo(PhotoMedia(image: .init(fileId: 1, width: 1, height: 1), largest: .init(fileId: 1, width: 1, height: 1), thumbnail: .init(fileId: 1, width: 1, height: 1), minithumbnail: nil), caption: HushCore.RichText(secret)))
        #expect(caption.previewText == "Photo: \(masked)")
        let snippet = ChatSearchView.snippet(for: ChatSearch.Result(message: text, matchesWords: true, matchesMeaning: false), query: "4417")
        #expect(String(snippet.characters) == masked)
    }

    @Test func spoilersMergeAndHideTheirLength() {
        let text = HushCore.RichText(text: "a secret b longer secret c", spans: [
            .init(range: 2..<8, style: .spoiler),
            .init(range: 5..<9, style: .spoiler),  // overlaps the first
            .init(range: 11..<24, style: .spoiler),
            .init(range: 11..<17, style: .bold),
        ])
        #expect(text.textHidingSpoilers == "a ▒▒▒▒b ▒▒▒▒ c")
        // A spoiler with an edge inside an emoji masks the whole emoji.
        let emoji = HushCore.RichText(text: "it's 👍🏽!", spans: [.init(range: 5..<7, style: .spoiler)])
        #expect(emoji.textHidingSpoilers == "it's ▒▒▒▒!")
        #expect(HushCore.RichText(text: "plain").textHidingSpoilers == "plain")
    }
}
