@preconcurrency import TDLibKit

extension ChatKind {
    /// Classifies a TDLib chat. TDLib always sends a user or supergroup before any chat that
    /// refers to it, so the lookups are current by the time a chat arrives.
    static func classify(
        _ type: ChatType,
        chatId: Int64,
        myUserId: Int64?,
        serviceChatId: Int64,
        isBot: (Int64) -> Bool,
        isDirectMessagesGroup: (Int64) -> Bool
    ) -> ChatKind {
        switch type {
        case .chatTypePrivate(let chat):
            if chat.userId == myUserId { return .savedMessages }
            if chatId == serviceChatId { return .service }
            return isBot(chat.userId) ? .bot : .person
        case .chatTypeSecret:
            return .secret
        case .chatTypeBasicGroup:
            return .group
        case .chatTypeSupergroup(let chat):
            // A channel's direct-messages group belongs to the channel.
            return chat.isChannel || isDirectMessagesGroup(chat.supergroupId) ? .channel : .group
        }
    }
}
