@preconcurrency import TDLibKit
import Foundation
import Observation

/// The two chat lists Hush shows: the main list and the Archive.
public enum ChatListKind: Sendable {
    case main
    case archive

    var tdList: ChatList {
        switch self {
        case .main: .chatListMain
        case .archive: .chatListArchive
        }
    }
}

/// One chat as the chat list shows it. Each row observes only its own chat, so a new message
/// redraws one row, not the whole list.
@MainActor @Observable
public final class ChatItem: Identifiable {
    public nonisolated let id: Int64
    public internal(set) var kind: ChatKind = .person
    public internal(set) var title: String
    public internal(set) var accentColorId: Int
    /// The small profile photo, if the chat has one.
    public internal(set) var photoFileId: Int?
    /// A tiny, blurry JPEG to show until the photo downloads.
    public internal(set) var photoThumbnail: Data?
    public internal(set) var preview = ""
    public internal(set) var lastActivity: Foundation.Date?
    public internal(set) var draft: String?
    public internal(set) var unreadCount: Int
    public internal(set) var unreadMentionCount: Int
    public internal(set) var isMarkedAsUnread: Bool
    public internal(set) var isMuted = false
    /// For one-on-one chats: online, or when last seen.
    public internal(set) var presence: Presence?
    var positions: [ChatPosition]

    // Raw TDLib state the store needs but views don't.
    @ObservationIgnored var type: ChatType
    @ObservationIgnored var lastMessage: Message?
    @ObservationIgnored var notificationSettings: ChatNotificationSettings
    @ObservationIgnored var lastReadInboxMessageId: Int64
    @ObservationIgnored var lastReadOutboxMessageId: Int64
    /// Your unsent draft as typed, line breaks included.
    @ObservationIgnored var rawDraft: String?
    @ObservationIgnored var availableReactions: ChatAvailableReactions

    init(_ chat: Chat) {
        id = chat.id
        title = chat.title
        accentColorId = chat.accentColorId
        photoFileId = chat.photo?.small.id
        photoThumbnail = chat.photo?.minithumbnail?.data
        draft = MessagePreview.draftText(chat.draftMessage)
        unreadCount = chat.unreadCount
        unreadMentionCount = chat.unreadMentionCount
        isMarkedAsUnread = chat.isMarkedAsUnread
        positions = chat.positions
        type = chat.type
        lastMessage = chat.lastMessage
        notificationSettings = chat.notificationSettings
        lastReadInboxMessageId = chat.lastReadInboxMessageId
        lastReadOutboxMessageId = chat.lastReadOutboxMessageId
        rawDraft = MessagePreview.rawDraftText(chat.draftMessage)
        availableReactions = chat.availableReactions
    }

    public var displayTitle: String {
        kind == .savedMessages ? "Saved Messages" : title
    }

    public var hasUnread: Bool {
        unreadCount > 0 || isMarkedAsUnread
    }

    /// The number on the row's badge: Telegram counts a chat marked as unread as one.
    public var unreadBadge: Int {
        unreadCount > 0 ? unreadCount : (isMarkedAsUnread ? 1 : 0)
    }

    public func isPinned(in list: ChatListKind) -> Bool {
        positions.contains { $0.isPinned && $0.list == list.tdList }
    }

    public func isIn(_ list: ChatListKind) -> Bool {
        positions.contains { $0.list == list.tdList }
    }

    var isJoinedTelegramStub: Bool {
        if case .messageContactRegistered = lastMessage?.content { return true }
        return false
    }
}
