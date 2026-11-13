import CoreText
import Foundation
import Testing
@preconcurrency import TDLibKit
@testable import HushCore

/// The one-line preview under each chat in the sidebar.
@MainActor
@Suite(.serialized)
struct ChatPreviewTests {
    /// The preview as read, without the invisible direction marks around names.
    private func preview(_ store: ChatStore, _ chatId: Int64) -> String {
        store.item(chatId)!.preview.filter { $0 != "\u{2068}" && $0 != "\u{2069}" }
    }

    /// An edit to the last message sticks, also when the preview is built again later (here: the
    /// chat's kind is worked out again after a user update).
    @Test func editedLastMessageStaysEdited() async {
        let store = Fixtures.store()
        store.handle(.updateUser(.init(user: Fixtures.user(70, "Max"))))
        let last = Fixtures.message(5, Fixtures.text("meet at 7"), chat: 70)
        store.handle(.updateNewChat(.init(chat: Fixtures.chat(70, "Max", positions: [Fixtures.position(1)], last: last))))
        await Fixtures.settle()
        store.handle(.updateMessageContent(.init(chatId: 70, messageId: 5, newContent: Fixtures.text("meet at 8"))))
        #expect(store.item(70)!.preview == "meet at 8")
        store.handle(.updateUser(.init(user: Fixtures.user(70, "Max", type: Fixtures.botType))))
        await Fixtures.settle()
        store.handle(.updateUser(.init(user: Fixtures.user(70, "Max"))))
        await Fixtures.settle()
        #expect(store.item(70)!.preview == "meet at 8")
    }

    @Test func memberEventsNameWhoDidWhat() async {
        let store = Fixtures.store()
        store.handle(.updateUser(.init(user: Fixtures.user(50, "Alice"))))
        store.handle(.updateUser(.init(user: Fixtures.user(51, "Bob"))))
        store.handle(.updateUser(.init(user: Fixtures.user(52, "Carol"))))
        func last(_ id: Int64, from sender: Int64, _ content: MessageContent, outgoing: Bool = false) {
            let message = Fixtures.message(id, content, chat: -60, from: sender, outgoing: outgoing)
            store.handle(.updateChatLastMessage(.init(chatId: -60, lastMessage: message, positions: [Fixtures.position(id)])))
        }
        store.handle(.updateNewChat(.init(chat: Fixtures.chat(-60, "Club", type: Fixtures.basicGroup(60), positions: [Fixtures.position(1)]))))

        last(1, from: 50, .messageChatAddMembers(.init(memberUserIds: [51])))
        #expect(preview(store, -60) == "Alice added Bob")
        last(2, from: 50, .messageChatAddMembers(.init(memberUserIds: [51, 52])))
        #expect(preview(store, -60) == "Alice added Bob and Carol")
        last(3, from: 50, .messageChatDeleteMember(.init(userId: 51)))
        #expect(preview(store, -60) == "Alice removed Bob")
        last(4, from: 51, .messageChatDeleteMember(.init(userId: 51)))
        #expect(preview(store, -60) == "Bob: Left the group")
        last(5, from: 51, .messageChatAddMembers(.init(memberUserIds: [51])))
        #expect(preview(store, -60) == "Bob: Joined the group")
        last(6, from: Fixtures.me, .messageChatDeleteMember(.init(userId: 52)), outgoing: true)
        #expect(preview(store, -60) == "You removed Carol")

        let created = Fixtures.message(1, .messageSupergroupChatCreate(.init(title: "News")), chat: -1009)
        store.handle(.updateNewChat(.init(chat: Fixtures.chat(-1009, "News", type: Fixtures.channel(9), positions: [Fixtures.position(1)], last: created))))
        #expect(preview(store, -1009) == "Channel created")
    }

    /// "محمد: lots of chatter" reads name, colon, text, with the text on the right. Without
    /// direction isolates the Arabic name makes the whole line right-to-left, and the text lands
    /// on the left with the colon on the wrong side.
    @Test func rightToLeftSenderKeepsTheLineInOrder() async throws {
        let store = Fixtures.store()
        store.handle(.updateUser(.init(user: Fixtures.user(3, "محمد عبد الرحمن"))))
        let message = Fixtures.message(1, Fixtures.text("lots of chatter"), chat: -8, from: 3)
        store.handle(.updateNewChat(.init(chat: Fixtures.chat(-8, "Group", type: Fixtures.basicGroup(8), positions: [Fixtures.position(1)], last: message))))
        let text = store.item(-8)!.preview as NSString
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text as String))
        let colon = CTLineGetOffsetForStringIndex(line, text.range(of: ":").location, nil)
        let words = CTLineGetOffsetForStringIndex(line, text.range(of: "lots").location, nil)
        #expect(words > colon, "the message text is drawn left of the colon: '\(text)'")
    }

    /// A long first name is cut, so the message still shows on the preview's lines.
    @Test func longSenderNameLeavesRoomForTheMessage() async {
        let store = Fixtures.store()
        store.handle(.updateUser(.init(user: Fixtures.user(2, "Maximilian Alexander Konstantin von Hohenzollern-Sigmaringen"))))
        let message = Fixtures.message(1, Fixtures.text("are you coming?"), chat: -7, from: 2)
        store.handle(.updateNewChat(.init(chat: Fixtures.chat(-7, "Group", type: Fixtures.basicGroup(7), positions: [Fixtures.position(1)], last: message))))
        let text = preview(store, -7)
        #expect(text.hasSuffix(": are you coming?"))
        #expect(text.count <= 24 + ": are you coming?".count, "got '\(text)'")
    }
}
