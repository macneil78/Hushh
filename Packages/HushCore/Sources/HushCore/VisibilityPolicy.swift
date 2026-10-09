/// What kind of conversation a chat is, as far as the distraction filter cares.
public enum ChatKind: Sendable, Hashable {
    /// A private chat with a person, contact or not.
    case person
    case savedMessages
    case secret
    case bot
    /// Telegram's own service-notifications account.
    case service
    /// Basic groups and supergroups that aren't channels.
    case group
    /// Broadcast channels, including their direct-message groups.
    case channel
}

/// The facts about one chat that decide whether it's shown.
public struct ChatSummary: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var kind: ChatKind
    public var title: String
    /// True when all the chat holds is Telegram's "X joined Telegram" notice.
    public var isJoinedTelegramStub: Bool

    public init(id: Int64, kind: ChatKind, title: String, isJoinedTelegramStub: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.isJoinedTelegramStub = isJoinedTelegramStub
    }
}

/// The user's explicit choice for one chat, overriding the default for its kind.
public enum VisibilityChoice: String, Codable, Sendable {
    case show
    case hide
}

/// The distraction filter. A chat that isn't visible gets no row, no notification and no Dock
/// badge count.
public enum VisibilityPolicy {
    public static func isVisible(_ chat: ChatSummary, choice: VisibilityChoice?) -> Bool {
        switch chat.kind {
        case .group, .channel, .bot, .service:
            // Hidden until you pick them. Picked channels come with Telegram's sponsored
            // messages, which its API terms require clients to show.
            return choice == .show
        case .person, .savedMessages, .secret:
            if let choice { return choice == .show }
            return !chat.isJoinedTelegramStub
        }
    }
}
