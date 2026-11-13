import AppKit
import Foundation
import Testing
@preconcurrency import TDLibKit
@testable import HushCore

/// The open conversation's state. The TDLib client is real but never logs in, so every request
/// fails, as it does offline.
@MainActor
@Suite(.serialized)
struct ConversationModelTests {
    // MARK: Reply quotes

    @Test func replyQuoteFollowsAnEditAndADeleteOfTheOriginal() async {
        let (model, _, _) = Fixtures.conversation()
        model.handle(Fixtures.newMessage(Fixtures.message(10, Fixtures.text("meet at 5"))))
        model.handle(Fixtures.newMessage(Fixtures.message(11, Fixtures.text("ok"), outgoing: true, replyTo: Fixtures.reply(to: 10))))
        #expect(model.messages[1].reply?.text == "meet at 5")
        model.handle(.updateMessageContent(.init(chatId: Fixtures.chatId, messageId: 10, newContent: Fixtures.text("meet at 7"))))
        #expect(model.messages[1].reply?.text == "meet at 7")
        #expect(model.timeline == Timeline.build(model.messages, firstUnreadMessageId: nil))
        model.handle(.updateDeleteMessages(.init(chatId: Fixtures.chatId, fromCache: false, isPermanent: true, messageIds: [10])))
        #expect(model.messages.map(\.id) == [11])
        #expect(model.messages[0].reply?.text == "Deleted message")
    }

    @Test func aFailedReplyLookupIsNotTakenForADeletedMessage() async {
        let (model, _, _) = Fixtures.conversation()
        model.handle(Fixtures.newMessage(Fixtures.message(50, Fixtures.text("sure"), replyTo: Fixtures.reply(to: 10))))
        await Fixtures.settle(600)
        // The lookup failed because the client is offline (here: not logged in). That says
        // nothing about the message, so the reply shows no quote rather than "Deleted message".
        #expect(model.messages.first { $0.id == 50 }?.reply == nil)
        // The original turns up (older history loads, or it arrives late): the quote follows.
        model.handle(Fixtures.newMessage(Fixtures.message(10, Fixtures.text("can you come?"))))
        #expect(model.messages.map(\.id) == [10, 50])
        #expect(model.messages.first { $0.id == 50 }?.reply?.text == "can you come?")
    }

    // MARK: Loading history

    @Test func aFailedFirstLoadIsRetriedFromTheOldestMessage() async {
        let (model, _, _) = Fixtures.conversation()
        await model.open()
        #expect(model.historyError != nil)  // shown with "Try Again"
        #expect(model.errorMessage == nil)
        #expect(model.hasOlderMessages)
        model.dismissHistoryError()
        model.handle(Fixtures.newMessage(Fixtures.message(500, Fixtures.text("new one"))))
        // Scrolling up (or "Try Again") asks TDLib for history before message 500. It fails
        // again here, offline, which shows that it asked.
        let loaded = await model.loadOlder()
        #expect(!loaded)
        #expect(model.historyError != nil)
        model.close()
    }

    // MARK: Unread divider

    @Test func theUnreadDividerMovesToTheNextUnreadWhenTheFirstIsDeleted() async {
        let (model, _, _) = Fixtures.conversation(Fixtures.chat(unread: 3, lastReadInbox: 10))
        model.handle(Fixtures.newMessage(Fixtures.message(10, Fixtures.text("read"))))
        model.handle(Fixtures.newMessage(Fixtures.message(11, Fixtures.text("first unread"))))
        model.handle(Fixtures.newMessage(Fixtures.message(12, Fixtures.text("my answer"), outgoing: true)))
        model.handle(Fixtures.newMessage(Fixtures.message(13, Fixtures.text("second unread"))))
        await model.open()  // history fails offline; the divider goes above what's loaded
        #expect(model.firstUnreadMessageId == 11)
        model.handle(.updateDeleteMessages(.init(chatId: Fixtures.chatId, fromCache: false, isPermanent: true, messageIds: [11])))
        #expect(model.firstUnreadMessageId == 13)
        #expect(model.timeline.contains(.unreadDivider))
        #expect(model.timeline == Timeline.build(model.messages, firstUnreadMessageId: 13))
        model.handle(.updateDeleteMessages(.init(chatId: Fixtures.chatId, fromCache: false, isPermanent: true, messageIds: [13])))
        #expect(model.firstUnreadMessageId == nil)
        #expect(!model.timeline.contains(.unreadDivider))
        model.close()
    }

    // MARK: Channels you can only read

    private func readOnlyChannel() -> ConversationModel {
        Fixtures.conversation(Fixtures.chat(type: Fixtures.channel(77)), kind: .channel).0
    }

    @Test func replyingIsNotPossibleWhereYouCantPost() async {
        let model = readOnlyChannel()
        model.handle(Fixtures.newMessage(Fixtures.message(10, Fixtures.text("channel post"))))
        #expect(!model.canPost)
        model.reply(to: model.messages[0])
        #expect(model.replyingTo == nil)  // no hidden reply for Esc to cancel
        #expect(!model.cancelComposerMode())
    }

    @Test func deletionShowsAnErrorWhenTDLibCantSayWhatsAllowed() async {
        let model = readOnlyChannel()
        model.handle(Fixtures.newMessage(Fixtures.message(10, Fixtures.text("channel post"))))
        model.requestDeletion(of: model.messages)
        await Fixtures.settle(600)
        #expect(model.pendingDeletion == nil)  // no "Delete for Me" that would fail
        #expect(model.errorMessage != nil)
    }

    // MARK: Typing

    @Test func typingSaysWhoDoesWhatInTheOrderTheyStarted() async {
        let (model, _, _) = Fixtures.conversation(
            Fixtures.chat(type: Fixtures.basicGroup(3)),
            kind: .group,
            users: [Fixtures.user(5, "Alex"), Fixtures.user(6, "Sam"), Fixtures.user(7, "Kim")]
        )
        func act(_ user: Int64, _ action: ChatAction) {
            model.handle(.updateChatAction(.init(action: action, chatId: Fixtures.chatId, senderId: .messageSenderUser(.init(userId: user)), topicId: nil)))
        }
        act(6, .chatActionTyping)
        act(5, .chatActionTyping)
        #expect(model.typingText == "Sam and Alex are typing…")
        #expect(model.typist?.name == "Sam")
        act(6, .chatActionRecordingVoiceNote)  // a new action keeps Sam's place
        #expect(model.typingText == "Sam is recording a voice message and Alex is typing…")
        act(6, .chatActionCancel)
        #expect(model.typingText == "Alex is typing…")
        #expect(model.typist?.name == "Alex")
        act(5, .chatActionCancel)
        #expect(model.typingText == nil)
        #expect(model.typist == nil)
    }

    // MARK: Sponsored messages

    @Test func anAdSeenWhileHushhIsInTheBackgroundCountsOnceHushhIsActive() async {
        let model = readOnlyChannel()
        var isActive = false
        model.isAppActive = { isActive }
        model.sponsoredAd = SponsoredAd(
            id: 42, title: "Example", body: .text(RichText(text: "Try it")), buttonText: "Open", url: "https://example.com",
            isRecommended: false, canBeReported: true, sponsorInfo: "", additionalInfo: "", accentColorId: 0, sponsorPhoto: nil
        )
        model.sponsoredAdVisibilityChanged(isFullyVisible: true)
        #expect(!model.isSponsoredAdViewed)  // Hushh is in the background
        isActive = true
        model.appBecameActive()
        #expect(model.isSponsoredAdViewed)  // still on screen when Hushh became active

        let other = readOnlyChannel()
        other.isAppActive = { isActive }
        other.sponsoredAd = model.sponsoredAd
        isActive = false
        other.sponsoredAdVisibilityChanged(isFullyVisible: true)
        other.sponsoredAdVisibilityChanged(isFullyVisible: false)  // scrolled away meanwhile
        isActive = true
        other.appBecameActive()
        #expect(!other.isSponsoredAdViewed)
    }
}
