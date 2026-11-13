import Foundation
import Testing
@preconcurrency import TDLibKit
@testable import HushCore

/// One unreadable field anywhere in an update or a history page must cost only that field (or
/// the list item around it), never the whole update or page. Fuzzed with every single-field
/// mutation of realistic updates: a field left out, or an "@type" TDLibKit doesn't know.
struct UpdateDecodingTests {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    /// A message with a reaction, a reply and a forward; `secondReaction` adds a second reaction.
    private func richMessage(id: Int64, chatId: Int64, secondReaction: Bool = false) -> Message {
        var list = [
            MessageReaction(isChosen: false, recentSenderIds: [.messageSenderUser(.init(userId: 7))], totalCount: 3, type: .reactionTypeEmoji(.init(emoji: "👍")), usedSenderId: nil),
        ]
        if secondReaction {
            list.append(MessageReaction(isChosen: true, recentSenderIds: [], totalCount: 1, type: .reactionTypeEmoji(.init(emoji: "❤️")), usedSenderId: nil))
        }
        let reactions = MessageReactions(areTags: false, canGetAddedReactions: true, paidReactors: [], reactions: list)
        return Fixtures.message(
            id, Fixtures.text("message \(id)"), chat: chatId, from: 7, date: 1_760_000_000,
            replyTo: Fixtures.reply(to: id - 1, in: chatId),
            forward: MessageForwardInfo(date: 1_750_000_000, origin: .messageOriginUser(.init(senderUserId: 8)), publicServiceAnnouncementType: "", source: nil),
            interaction: MessageInteractionInfo(forwardCount: 0, reactions: reactions, replyInfo: nil, viewCount: 10)
        )
    }

    private func samples() -> [(String, Update)] {
        let chatId: Int64 = 7
        let message = richMessage(id: 100, chatId: chatId)
        return [
            ("updateNewMessage", .updateNewMessage(.init(message: message))),
            ("updateNewChat", .updateNewChat(.init(chat: Fixtures.chat(chatId, "Alex", positions: [Fixtures.position(5)], last: message)))),
            ("updateChatLastMessage", .updateChatLastMessage(.init(chatId: chatId, lastMessage: message, positions: [Fixtures.position(6)]))),
            ("updateUser", .updateUser(.init(user: Fixtures.user(7, "Alex", status: .userStatusOnline(.init(expires: 1_800_000_000)))))),
            ("updateUserStatus", .updateUserStatus(.init(status: .userStatusOffline(.init(wasOnline: 1_760_000_000)), userId: 7))),
        ]
    }

    /// TDLib names every object's type; TDLibKit's encoder only names enum cases. Adds the names
    /// of the objects these tests look at, as TDLib would send them.
    private func tagged(_ value: Any, key: String? = nil) -> Any {
        let names = ["message": "message", "last_message": "message", "chat": "chat", "user": "user"]
        if var object = value as? [String: Any] {
            if object["@type"] == nil, let key, let name = names[key] { object["@type"] = name }
            for (childKey, child) in object { object[childKey] = tagged(child, key: childKey) }
            return object
        }
        if let array = value as? [Any] { return array.map { tagged($0) } }
        return value
    }

    /// Every single-field mutation of `json`: a missing key, or an unknown "@type".
    private func mutations(of value: Any, path: String = "") -> [(path: String, apply: (Any) -> Any)] {
        var result: [(String, (Any) -> Any)] = []
        if let object = value as? [String: Any] {
            for (key, child) in object {
                if key == "@type" {
                    if let type = child as? String, !path.isEmpty {
                        result.append((path + " @type", { root in Self.set(root, path: path, key: "@type", to: "\(type)Future") }))
                    }
                    continue
                }
                result.append((path + "." + key, { root in Self.set(root, path: path, key: key, to: nil) }))
                result.append(contentsOf: mutations(of: child, path: path + "." + key))
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                result.append(contentsOf: mutations(of: child, path: path + "[\(index)]"))
            }
        }
        return result
    }

    /// Sets (or removes, with nil) `key` in the object at `path`.
    private static func set(_ root: Any, path: String, key: String, to newValue: Any?) -> Any {
        func walk(_ node: Any, _ parts: ArraySlice<String>) -> Any {
            guard let part = parts.first else {
                var object = node as! [String: Any]
                object[key] = newValue
                return object
            }
            if part.hasPrefix("["), let index = Int(part.dropFirst().dropLast()) {
                var array = node as! [Any]
                array[index] = walk(array[index], parts.dropFirst())
                return array
            }
            var object = node as! [String: Any]
            object[part] = walk(object[part]!, parts.dropFirst())
            return object
        }
        var parts: [String] = []
        for piece in path.split(separator: ".") {
            var name = String(piece)
            var indices: [String] = []
            while let open = name.lastIndex(of: "[") {
                indices.insert(String(name[open...]), at: 0)
                name = String(name[..<open])
            }
            parts.append(name)
            parts.append(contentsOf: indices)
        }
        return walk(root, ArraySlice(parts))
    }

    @Test func oneUnreadableFieldNeverDropsAnUpdate() throws {
        // What can't be shown at all: the whole payload missing, a chat of a kind Hushh doesn't
        // know, a message without a sender.
        let unrepresentable: Set<String> = [
            ".message", ".chat", ".user", ".status",
            ".chat.type", ".chat.type @type", ".message.sender_id", ".message.sender_id @type",
        ]
        var total = 0
        for (name, update) in samples() {
            let json = try JSONSerialization.jsonObject(with: encoder.encode(update))
            // Each mutation, applied to the JSON as TDLib sends it.
            for mutation in mutations(of: json) {
                total += 1
                let data = try JSONSerialization.data(withJSONObject: mutation.apply(tagged(json)))
                if (try? ResilientDecoding.decode(Update.self, from: data, decoder: decoder)) == nil {
                    #expect(unrepresentable.contains(mutation.path), "\(name)\(mutation.path) dropped the whole update")
                }
            }
        }
        #expect(total == 307)
    }

    @Test func oneUnreadableReactionCostsOnlyThatReaction() throws {
        let page = Messages(messages: (1...100).map { richMessage(id: Int64($0 + 1), chatId: 7, secondReaction: true) }, totalCount: 100)
        var json = try JSONSerialization.jsonObject(with: encoder.encode(page)) as! [String: Any]
        var messages = json["messages"] as! [[String: Any]]
        var interaction = messages[42]["interaction_info"] as! [String: Any]
        var reactions = interaction["reactions"] as! [String: Any]
        var list = reactions["reactions"] as! [[String: Any]]
        list[0]["type"] = ["@type": "reactionTypeFuture"]
        reactions["reactions"] = list
        interaction["reactions"] = reactions
        messages[42]["interaction_info"] = interaction
        json["messages"] = messages
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: (any Swift.Error).self) { try decoder.decode(Messages.self, from: data) }

        let decoded = try ResilientDecoding.decode(Messages.self, from: data, decoder: decoder)
        #expect(decoded.messages == page.messages.map { messages in
            var messages = messages
            let original = messages[42]
            let kept = original.interactionInfo?.reactions?.reactions.dropFirst()
            messages[42] = Fixtures.message(
                original.id, original.content, chat: 7, from: 7, date: original.date,
                replyTo: original.replyTo, forward: original.forwardInfo,
                interaction: MessageInteractionInfo(forwardCount: 0, reactions: MessageReactions(areTags: false, canGetAddedReactions: true, paidReactors: [], reactions: Array(kept ?? [])), replyInfo: nil, viewCount: 10)
            )
            return messages
        })
    }

    @Test func aMessageThatCantBeReadLeavesTheRestOfThePage() throws {
        let page = Messages(messages: (1...20).map { richMessage(id: Int64($0 + 1), chatId: 7) }, totalCount: 20)
        var json = try JSONSerialization.jsonObject(with: encoder.encode(page)) as! [String: Any]
        var messages = json["messages"] as! [[String: Any]]
        messages[5]["sender_id"] = NSNull()
        json["messages"] = messages
        let decoded = try ResilientDecoding.decode(Messages.self, from: JSONSerialization.data(withJSONObject: json), decoder: decoder)
        #expect(decoded.messages?.map(\.id) == page.messages?.map(\.id).filter { $0 != 7 })
    }

    @Test func aChatWithNullSettingsStillReachesTheList() throws {
        let update = Update.updateNewChat(.init(chat: Fixtures.chat(9, "Climbing", type: Fixtures.basicGroup(3), positions: [Fixtures.position(5)])))
        var json = try tagged(JSONSerialization.jsonObject(with: encoder.encode(update))) as! [String: Any]
        var chat = json["chat"] as! [String: Any]
        chat["notification_settings"] = NSNull()
        chat["available_reactions"] = ["@type": "chatAvailableReactionsFuture"]
        json["chat"] = chat
        let decoded = try ResilientDecoding.decode(Update.self, from: JSONSerialization.data(withJSONObject: json), decoder: decoder)
        guard case .updateNewChat(let new) = decoded else { Issue.record("not a new chat"); return }
        #expect(new.chat.id == 9 && new.chat.title == "Climbing" && new.chat.positions.count == 1)
        #expect(new.chat.notificationSettings.muteFor == 0)
        #expect(new.chat.availableReactions == .chatAvailableReactionsSome(.init(maxReactionCount: 0, reactions: [])))
    }

    @Test func aStatusOfANewKindReadsAsUnknown() throws {
        let update = Update.updateUser(.init(user: Fixtures.user(7, "Alex")))
        var json = try tagged(JSONSerialization.jsonObject(with: encoder.encode(update))) as! [String: Any]
        var user = json["user"] as! [String: Any]
        user["status"] = ["@type": "userStatusInSpace", "expires": 5]
        json["user"] = user
        let decoded = try ResilientDecoding.decode(Update.self, from: JSONSerialization.data(withJSONObject: json), decoder: decoder)
        guard case .updateUser(let changed) = decoded else { Issue.record("not a user"); return }
        #expect(changed.user.firstName == "Alex")
        #expect(changed.user.status == .userStatusEmpty)
    }
}
