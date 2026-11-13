import Foundation
import Testing
@preconcurrency import TDLibKit
@testable import HushCore

/// The open conversation keeps its timeline in step with its messages without rebuilding it
/// for every update.
@MainActor
@Suite(.serialized)
struct TimelineUpdateTests {
    /// A small, seeded generator, so a failure can be replayed.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    /// Random updates of every kind the conversation handles. After each one, the timeline must
    /// be what a full rebuild from the messages gives.
    @Test(arguments: [1, 2, 3, 4, 5, 6])
    func timelineMatchesAFullRebuildAfterRandomUpdates(seed: UInt64) async {
        var random = SeededGenerator(state: seed)
        let (model, _, _) = Fixtures.conversation(
            Fixtures.chat(type: Fixtures.basicGroup(3), unread: 5, lastReadInbox: 300),
            kind: .group,
            users: [Fixtures.user(5, "Alex"), Fixtures.user(6, "Sam"), Fixtures.user(7, "Kim")]
        )
        var nextId: Int64 = 200
        var date = 1_763_000_000
        func randomMessage(id: Int64, album: Int64 = 0) -> Message {
            let outgoing = Int.random(in: 0..<4, using: &random) == 0
            let sender = Int64.random(in: 5...7, using: &random)
            let content: MessageContent = Int.random(in: 0..<12, using: &random) == 0
                ? .messageChatAddMembers(.init(memberUserIds: [sender]))
                : Fixtures.text("message \(id)")
            let loaded = model.messages.map(\.id)
            let replyTo = Int.random(in: 0..<4, using: &random) == 0 ? loaded.randomElement(using: &random) : nil
            return Fixtures.message(id, content, from: sender, outgoing: outgoing, date: date, replyTo: replyTo.map { Fixtures.reply(to: $0) }, album: album)
        }
        func check(_ step: String) {
            let rebuilt = Timeline.build(model.messages, firstUnreadMessageId: model.firstUnreadMessageId)
            #expect(model.timeline == rebuilt, "seed \(seed), after \(step)")
            #expect(model.messages.map(\.id) == model.messages.map(\.id).sorted(), "seed \(seed), after \(step)")
            let rowIds = model.timeline.map(\.id)
            #expect(Set(rowIds).count == rowIds.count, "seed \(seed), after \(step): repeated row ids")
        }

        for _ in 0..<40 {
            date += [10, 60, 400, 4_000, 90_000].randomElement(using: &random)!
            model.handle(Fixtures.newMessage(randomMessage(id: nextId)))
            nextId += 1
        }
        await model.open()  // history fails offline; the unread divider is placed among what's loaded
        check("open")

        for step in 0..<400 {
            let loaded = model.messages.map(\.id)
            let target = loaded.randomElement(using: &random)
            switch Int.random(in: 0..<11, using: &random) {
            case 0, 1:
                date += [5, 60, 400, 4_000, 90_000].randomElement(using: &random)!
                model.handle(Fixtures.newMessage(randomMessage(id: nextId)))
                nextId += 1
            case 2:
                // An album of a few photos (text stands in for them; only the album id matters here).
                date += 30
                let album = Int64.random(in: 1...1_000_000, using: &random)
                for _ in 0..<Int.random(in: 2...4, using: &random) {
                    model.handle(Fixtures.newMessage(randomMessage(id: nextId, album: album)))
                    nextId += 1
                }
            case 3:
                // Older history, or a message that turns up between loaded ones.
                if let first = loaded.first {
                    model.handle(Fixtures.newMessage(randomMessage(id: first - Int64.random(in: 1...5, using: &random))))
                }
            case 4:
                if let target {
                    model.handle(.updateMessageContent(.init(chatId: Fixtures.chatId, messageId: target, newContent: Fixtures.text("edited \(step)"))))
                }
            case 5:
                // Content that Hushh hides: the message leaves the timeline.
                if let target {
                    model.handle(.updateMessageContent(.init(chatId: Fixtures.chatId, messageId: target, newContent: .messageChatUpgradeTo(.init(supergroupId: 1)))))
                }
            case 6:
                if let target {
                    let reaction = MessageReaction(isChosen: false, recentSenderIds: [], totalCount: Int.random(in: 1...9, using: &random), type: .reactionTypeEmoji(.init(emoji: "👍")), usedSenderId: nil)
                    model.handle(.updateMessageInteractionInfo(.init(chatId: Fixtures.chatId, interactionInfo: Fixtures.reactions([reaction]), messageId: target)))
                }
            case 7:
                if let target {
                    model.handle(.updateMessageEdited(.init(chatId: Fixtures.chatId, editDate: 5, messageId: target, replyMarkup: nil)))
                }
            case 8:
                let ids = Array(Set((0..<Int.random(in: 1...3, using: &random)).compactMap { _ in loaded.randomElement(using: &random) }))
                model.handle(.updateDeleteMessages(.init(chatId: Fixtures.chatId, fromCache: false, isPermanent: true, messageIds: ids)))
            case 9:
                // A message you send: pending first, then its real id.
                date += 20
                let temp = nextId + 1_000_000
                let pending = Fixtures.message(temp, Fixtures.text("sending"), outgoing: true, date: date, sending: .messageSendingStatePending(.init(sendingId: 1)))
                model.handle(Fixtures.newMessage(pending))
                model.handle(.updateMessageSendSucceeded(.init(message: Fixtures.message(nextId, Fixtures.text("sent"), outgoing: true, date: date), oldMessageId: temp)))
                nextId += 1
            default:
                // The same message again (TDLib repeats updateNewMessage at times).
                if let target, let message = model.messages.first(where: { $0.id == target }) {
                    model.handle(Fixtures.newMessage(Fixtures.message(target, Fixtures.text(message.plainText), from: message.sender.id, outgoing: message.isOutgoing, date: Int(message.date.timeIntervalSince1970), album: message.albumId)))
                }
            }
            check("step \(step)")
        }
        model.close()
    }

    private func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// A new message, a reaction or an edit costs about the same at any history size, also with
    /// thousands of messages loaded (after a jump to an old search result, say).
    @Test func aNewMessageCostsTheSameWithLongHistory() async {
        let (model, _, _) = Fixtures.conversation(
            Fixtures.chat(type: Fixtures.basicGroup(3)),
            kind: .group,
            users: [Fixtures.user(5, "Alex"), Fixtures.user(6, "Sam")]
        )
        let clock = ContinuousClock()
        var report: [String] = []
        var costs: [Int: Double] = [:]
        var windowStart = clock.now
        var windowCount = 0
        for index in 1...3_000 {
            let message = Fixtures.message(Int64(index) << 20, Fixtures.text("hi \(index)"), from: 5 + Int64(index % 2), date: 1_760_000_000 + index * 30)
            model.handle(Fixtures.newMessage(message))
            windowCount += 1
            if [250, 500, 1_000, 2_000, 3_000].contains(index) {
                let perMessage = ms(clock.now - windowStart) / Double(windowCount)
                costs[index] = perMessage
                report.append("\(index) loaded: \(String(format: "%.3f", perMessage)) ms")
                windowStart = clock.now
                windowCount = 0
            }
        }
        // A reaction on a message far up, and an edit of one.
        let middle = model.messages[1_500].id
        var start = clock.now
        for count in 1...200 {
            let reaction = MessageReaction(isChosen: false, recentSenderIds: [], totalCount: count, type: .reactionTypeEmoji(.init(emoji: "👍")), usedSenderId: nil)
            model.handle(.updateMessageInteractionInfo(.init(chatId: Fixtures.chatId, interactionInfo: Fixtures.reactions([reaction]), messageId: middle)))
        }
        let reactionMs = ms(clock.now - start) / 200
        start = clock.now
        for count in 1...200 {
            model.handle(.updateMessageContent(.init(chatId: Fixtures.chatId, messageId: middle, newContent: Fixtures.text("edit \(count)"))))
        }
        let editMs = ms(clock.now - start) / 200

        #expect(model.messages.count == 3_000)
        #expect(model.timeline == Timeline.build(model.messages, firstUnreadMessageId: nil))
        // Generous bounds for a debug build on a busy machine; a full rebuild takes 20 ms and more.
        #expect(costs[3_000]! < 2, "per message: \(report.joined(separator: "; "))")
        #expect(reactionMs < 2, "\(reactionMs) ms per reaction")
        #expect(editMs < 2, "\(editMs) ms per edit")
    }

    private func message(_ id: Int64, from sender: Int64, at date: Foundation.Date, album: Int64 = 0) -> MessageModel {
        MessageModel(
            id: id, date: date, isOutgoing: false,
            sender: .init(id: sender, name: "User \(sender)", accentColorId: 0, photoFileId: nil),
            body: .text(RichText(text: "x")), replyToMessageId: nil, reply: nil, forwardedFrom: nil,
            isEdited: false, status: .sent, albumId: album
        )
    }

    @Test func rowIdsStayUniqueWhenAnAlbumIsInterruptedOrDatesRunBackwards() {
        let t = Foundation.Date(timeIntervalSince1970: 1_763_000_000)
        let interrupted = Timeline.build([
            message(1, from: 7, at: t, album: 9), message(2, from: 7, at: t, album: 9), message(3, from: 8, at: t),
            message(4, from: 7, at: t, album: 9), message(5, from: 7, at: t, album: 9),
        ], firstUnreadMessageId: nil)
        #expect(Set(interrupted.map(\.id)).count == interrupted.count)
        // In id order, but the dates go back: a pending message stamped by a clock that runs ahead.
        let backwards = Timeline.build([message(1, from: 7, at: t), message(2, from: 8, at: t + 2 * 86400), message(3, from: 7, at: t)], firstUnreadMessageId: nil)
        #expect(Set(backwards.map(\.id)).count == backwards.count)
    }

    @Test func customEmojiReactionsHaveTheirOwnIds() async {
        let (model, _, _) = Fixtures.conversation()
        let custom: (Int64, Int) -> MessageReaction = { id, count in
            MessageReaction(isChosen: false, recentSenderIds: [], totalCount: count, type: .reactionTypeCustomEmoji(.init(customEmojiId: TdInt64(rawValue: id)!)), usedSenderId: nil)
        }
        model.handle(Fixtures.newMessage(Fixtures.message(10, Fixtures.text("post"), interaction: Fixtures.reactions([custom(1, 4), custom(2, 3)]))))
        let ids = model.messages[0].reactions.map(\.id)
        #expect(Set(ids).count == 2)
    }
}
