@preconcurrency import TDLibKit
import Foundation
import Observation

/// Every chat TDLib knows about, kept current from updates, plus the filtered and sorted lists
/// the sidebar shows.
@MainActor @Observable
public final class ChatStore {
    /// Visible chats in the main list, in Telegram's order (pinned first, then most recent).
    public private(set) var mainList: [ChatItem] = []
    /// Visible archived chats, in the same order.
    public private(set) var archiveList: [ChatItem] = []
    /// Unread messages in visible, unmuted chats of the main list.
    public private(set) var badgeCount = 0
    /// True once both chat lists have been fully loaded from TDLib.
    public private(set) var isLoaded = false

    @ObservationIgnored var onBadgeCountChange: ((Int) -> Void)?
    @ObservationIgnored var serviceChatId: Int64 = 777000

    let visibility = VisibilitySettings()
    @ObservationIgnored private let files: FileStore
    @ObservationIgnored private var client: TDLibClient?
    @ObservationIgnored private var myUserId: Int64?
    @ObservationIgnored private var items: [Int64: ChatItem] = [:]
    @ObservationIgnored private var users: [Int64: Person] = [:]
    @ObservationIgnored private var directMessagesGroupIds: Set<Int64> = []
    @ObservationIgnored private var scopeMuted = ScopeMuted()
    @ObservationIgnored private var isRebuildScheduled = false
    /// Every emoji Telegram currently offers as a reaction, in its order.
    @ObservationIgnored private var activeEmojiReactions: [String] = []

    private struct ScopeMuted {
        var privateChats = false
        var groups = false
        var channels = false
    }

    init(files: FileStore) {
        self.files = files
    }

    public func item(_ id: Int64) -> ChatItem? {
        items[id]
    }

    /// A Telegram user, as messages show them.
    public func person(_ userId: Int64) -> Person? {
        users[userId]
    }

    /// The emoji reactions a chat allows, in Telegram's order.
    public func reactionChoices(for chatId: Int64) -> [String] {
        guard let item = items[chatId] else { return [] }
        switch item.availableReactions {
        case .chatAvailableReactionsAll:
            return activeEmojiReactions
        case .chatAvailableReactionsSome(let some):
            return some.reactions.compactMap {
                if case .reactionTypeEmoji(let reaction) = $0 { return reaction.emoji }
                return nil
            }
        }
    }

    public func list(_ kind: ChatListKind) -> [ChatItem] {
        switch kind {
        case .main: mainList
        case .archive: archiveList
        }
    }

    // MARK: Choosing what's shown

    /// Whether the first-run "Choose Groups & Bots" sheet should open.
    public var shouldOfferChoosing: Bool {
        isLoaded && visibility.isLoaded && !visibility.hasChosenGroupsAndBots
    }

    public func finishChoosing() {
        visibility.markChosen()
    }

    /// Whether a chat passes the distraction filter, by id. Hidden chats never notify.
    func isVisible(_ chatId: Int64) -> Bool {
        items[chatId].map(isShown) ?? false
    }

    public func isShown(_ item: ChatItem) -> Bool {
        VisibilityPolicy.isVisible(summary(of: item), choice: visibility.choices[item.id])
    }

    public func setShown(_ isShown: Bool, for item: ChatItem) {
        let choice: VisibilityChoice? = switch item.kind {
        case .group, .bot, .service: isShown ? .show : nil
        case .person, .savedMessages, .secret: isShown ? nil : .hide
        case .channel: nil
        }
        visibility.setChoice(choice, for: item.id)
        scheduleRebuild()
    }

    /// What the "Choose Groups & Bots" sheet offers: every group, bot and service chat, plus people
    /// you've hidden, most recently active first.
    public func chatsToChoose() -> [ChatItem] {
        items.values
            .filter { item in
                guard item.isIn(.main) || item.isIn(.archive) else { return false }
                switch item.kind {
                case .group, .bot, .service: return true
                case .person, .savedMessages, .secret: return visibility.choices[item.id] == .hide
                case .channel: return false
                }
            }
            .sorted { ($0.lastActivity ?? Foundation.Date.distantPast) > ($1.lastActivity ?? Foundation.Date.distantPast) }
    }

    // MARK: Actions

    public func markAsRead(_ item: ChatItem) {
        guard let client else { return }
        let chatId = item.id
        let lastMessageId = item.lastMessage?.id
        let isMarkedAsUnread = item.isMarkedAsUnread
        let hasMentions = item.unreadMentionCount > 0
        Task {
            do {
                if let lastMessageId {
                    _ = try await client.viewMessages(chatId: chatId, forceRead: true, messageIds: [lastMessageId], source: nil)
                }
                if isMarkedAsUnread {
                    _ = try await client.toggleChatIsMarkedAsUnread(chatId: chatId, isMarkedAsUnread: false)
                }
                if hasMentions {
                    _ = try await client.readAllChatMentions(chatId: chatId)
                }
            } catch {
                Log.chats.error("Mark as read failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    public func markAsUnread(_ item: ChatItem) {
        guard let client else { return }
        let chatId = item.id
        Task { _ = try? await client.toggleChatIsMarkedAsUnread(chatId: chatId, isMarkedAsUnread: true) }
    }

    public func setArchived(_ isArchived: Bool, _ item: ChatItem) {
        guard let client else { return }
        let chatId = item.id
        let list = (isArchived ? ChatListKind.archive : .main).tdList
        Task {
            do {
                _ = try await client.addChatToList(chatId: chatId, chatList: list)
            } catch {
                Log.chats.error("Moving chat between lists failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Session lifecycle

    /// Connects to the session and loads your visibility choices.
    func attach(client: TDLibClient, myUserId: Int64, settingsFile: URL) {
        self.client = client
        self.myUserId = myUserId
        visibility.load(from: settingsFile)
        scheduleRebuild()
    }

    /// Loads both chat lists. Chats arrive through updates while this runs.
    func loadLists() async {
        guard let client else { return }
        for list in [ChatListKind.main, .archive] {
            while self.client === client {
                do {
                    _ = try await client.loadChats(chatList: list.tdList, limit: 200)
                } catch let error as TDLibKit.Error where error.code == 404 {
                    break  // everything is loaded
                } catch {
                    Log.chats.error("Loading chats failed: \(String(describing: error), privacy: .public)")
                    break
                }
            }
        }
        guard self.client === client else { return }
        isLoaded = true
    }

    func reset() {
        client = nil
        myUserId = nil
        items = [:]
        users = [:]
        directMessagesGroupIds = []
        scopeMuted = ScopeMuted()
        visibility.reset()
        mainList = []
        archiveList = []
        isLoaded = false
        if badgeCount != 0 {
            badgeCount = 0
            onBadgeCountChange?(0)
        }
    }

    // MARK: Updates

    func handle(_ update: Update) {
        switch update {
        case .updateNewChat(let update):
            let item = ChatItem(update.chat)
            items[item.id] = item
            if let photo = update.chat.photo { files.apply(photo.small) }
            item.kind = kind(of: item)
            refreshPreview(of: item)
            scheduleRebuild()
        case .updateChatTitle(let update):
            items[update.chatId]?.title = update.title
        case .updateChatPhoto(let update):
            guard let item = items[update.chatId] else { return }
            item.photoFileId = update.photo?.small.id
            item.photoThumbnail = update.photo?.minithumbnail?.data
            if let photo = update.photo { files.apply(photo.small) }
        case .updateChatAccentColors(let update):
            items[update.chatId]?.accentColorId = update.accentColorId
        case .updateChatPosition(let update):
            guard let item = items[update.chatId] else { return }
            item.positions.removeAll { $0.list == update.position.list }
            if update.position.order.rawValue != 0 { item.positions.append(update.position) }
            scheduleRebuild()
        case .updateChatLastMessage(let update):
            guard let item = items[update.chatId] else { return }
            item.lastMessage = update.lastMessage
            item.positions = update.positions
            refreshPreview(of: item)
            scheduleRebuild()
        case .updateMessageContent(let update):
            guard let item = items[update.chatId], let message = item.lastMessage, message.id == update.messageId else { return }
            refreshPreview(of: item, content: update.newContent)
        case .updateChatDraftMessage(let update):
            guard let item = items[update.chatId] else { return }
            item.draft = MessagePreview.draftText(update.draftMessage)
            item.rawDraft = MessagePreview.rawDraftText(update.draftMessage)
            item.positions = update.positions
            scheduleRebuild()
        case .updateChatReadInbox(let update):
            guard let item = items[update.chatId] else { return }
            item.unreadCount = update.unreadCount
            item.lastReadInboxMessageId = update.lastReadInboxMessageId
            scheduleRebuild()
        case .updateChatReadOutbox(let update):
            items[update.chatId]?.lastReadOutboxMessageId = update.lastReadOutboxMessageId
        case .updateChatUnreadMentionCount(let update):
            items[update.chatId]?.unreadMentionCount = update.unreadMentionCount
        case .updateMessageMentionRead(let update):
            items[update.chatId]?.unreadMentionCount = update.unreadMentionCount
        case .updateChatIsMarkedAsUnread(let update):
            items[update.chatId]?.isMarkedAsUnread = update.isMarkedAsUnread
            scheduleRebuild()
        case .updateChatNotificationSettings(let update):
            items[update.chatId]?.notificationSettings = update.notificationSettings
            scheduleRebuild()
        case .updateScopeNotificationSettings(let update):
            let isMuted = update.notificationSettings.muteFor > 0
            switch update.scope {
            case .notificationSettingsScopePrivateChats: scopeMuted.privateChats = isMuted
            case .notificationSettingsScopeGroupChats: scopeMuted.groups = isMuted
            case .notificationSettingsScopeChannelChats: scopeMuted.channels = isMuted
            }
            scheduleRebuild()
        case .updateUser(let update):
            let user = update.user
            let isBot = if case .userTypeBot = user.type { true } else { false }
            let previous = users[user.id]
            users[user.id] = Person(
                id: user.id,
                firstName: user.firstName,
                lastName: user.lastName,
                accentColorId: user.accentColorId,
                photoFileId: user.profilePhoto?.small.id,
                isBot: isBot
            )
            if let photo = user.profilePhoto { files.apply(photo.small) }
            if previous?.isBot != isBot { scheduleRebuild() }
        case .updateChatAvailableReactions(let update):
            items[update.chatId]?.availableReactions = update.availableReactions
        case .updateActiveEmojiReactions(let update):
            activeEmojiReactions = update.emojis
        case .updateSupergroup(let update):
            if update.supergroup.isDirectMessagesGroup, directMessagesGroupIds.insert(update.supergroup.id).inserted {
                scheduleRebuild()
            }
        default:
            break
        }
    }

    // MARK: Building the lists

    private func scheduleRebuild() {
        guard !isRebuildScheduled else { return }
        isRebuildScheduled = true
        // Coalesces the bursts of updates TDLib sends while loading into one rebuild.
        Task { [weak self] in self?.rebuild() }
    }

    private func rebuild() {
        isRebuildScheduled = false
        var main: [(item: ChatItem, order: Int64)] = []
        var archive: [(item: ChatItem, order: Int64)] = []
        for item in items.values {
            let kind = kind(of: item)
            if item.kind != kind {
                item.kind = kind
                refreshPreview(of: item)
            }
            let isMuted = isMuted(item)
            if item.isMuted != isMuted { item.isMuted = isMuted }

            guard VisibilityPolicy.isVisible(summary(of: item), choice: visibility.choices[item.id]) else { continue }
            for position in item.positions {
                switch position.list {
                case .chatListMain: main.append((item, position.order.rawValue))
                case .chatListArchive: archive.append((item, position.order.rawValue))
                case .chatListFolder: break
                }
            }
        }
        // TDLib orders chats by (order, id), both descending.
        let byOrder: ((item: ChatItem, order: Int64), (item: ChatItem, order: Int64)) -> Bool = {
            $0.order != $1.order ? $0.order > $1.order : $0.item.id > $1.item.id
        }
        let newMain = main.sorted(by: byOrder).map(\.item)
        let newArchive = archive.sorted(by: byOrder).map(\.item)
        if !newMain.elementsEqual(mainList, by: ===) { mainList = newMain }
        if !newArchive.elementsEqual(archiveList, by: ===) { archiveList = newArchive }

        let badge = newMain.reduce(0) { $1.isMuted ? $0 : $0 + $1.unreadBadge }
        if badge != badgeCount {
            badgeCount = badge
            onBadgeCountChange?(badge)
        }
    }

    private func kind(of item: ChatItem) -> ChatKind {
        ChatKind.classify(
            item.type,
            chatId: item.id,
            myUserId: myUserId,
            serviceChatId: serviceChatId,
            isBot: { users[$0]?.isBot ?? false },
            isDirectMessagesGroup: { directMessagesGroupIds.contains($0) }
        )
    }

    private func summary(of item: ChatItem) -> ChatSummary {
        ChatSummary(id: item.id, kind: item.kind, title: item.title, isJoinedTelegramStub: item.isJoinedTelegramStub)
    }

    /// Telegram mutes a chat by its own setting, or by the default for its kind when it has none.
    private func isMuted(_ item: ChatItem) -> Bool {
        let settings = item.notificationSettings
        guard settings.useDefaultMuteFor else { return settings.muteFor > 0 }
        return switch item.kind {
        case .group: scopeMuted.groups
        case .channel: scopeMuted.channels
        case .person, .savedMessages, .secret, .bot, .service: scopeMuted.privateChats
        }
    }

    private func refreshPreview(of item: ChatItem, content: MessageContent? = nil) {
        guard let message = item.lastMessage else {
            item.preview = ""
            item.lastActivity = nil
            return
        }
        let text = MessagePreview.text(for: content ?? message.content)
        let preview: String
        if message.isOutgoing, item.kind != .savedMessages {
            preview = "You: \(text)"
        } else if item.kind == .group, case .messageSenderUser(let sender) = message.senderId,
                  let name = users[sender.userId]?.firstName, !name.isEmpty {
            preview = "\(name): \(text)"
        } else {
            preview = text
        }
        if item.preview != preview { item.preview = preview }
        let date = Foundation.Date(timeIntervalSince1970: TimeInterval(message.date))
        if item.lastActivity != date { item.lastActivity = date }
    }
}

/// A Telegram user, as messages and avatars show them.
public struct Person: Equatable, Sendable {
    public let id: Int64
    public let firstName: String
    public let lastName: String
    public let accentColorId: Int
    public let photoFileId: Int?
    public let isBot: Bool

    /// Full name, or "Deleted Account" for accounts that no longer exist.
    public var name: String {
        let name = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? "Deleted Account" : name
    }
}
