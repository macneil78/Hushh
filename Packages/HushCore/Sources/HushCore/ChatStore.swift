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
    /// Why loading the chat lists stopped early, if it did.
    public private(set) var loadProblem: String?

    @ObservationIgnored var onBadgeCountChange: ((Int) -> Void)?
    @ObservationIgnored var serviceChatId: Int64 = 777000

    let visibility = VisibilitySettings()
    @ObservationIgnored private let files: FileStore
    @ObservationIgnored private var client: TDLibClient?
    @ObservationIgnored private var myUserId: Int64?
    @ObservationIgnored private var items: [Int64: ChatItem] = [:]
    @ObservationIgnored private var users: [Int64: Person] = [:]
    @ObservationIgnored private var directMessagesGroupIds: Set<Int64> = []
    /// Channels (by supergroup id) where you're an admin who may post.
    @ObservationIgnored private var postableChannelIds: Set<Int64> = []
    @ObservationIgnored private var basicGroupMemberCounts: [Int64: Int] = [:]
    @ObservationIgnored private var supergroupMemberCounts: [Int64: Int] = [:]
    @ObservationIgnored private var scopeMuted = ScopeMuted()
    @ObservationIgnored private var isRebuildScheduled = false
    /// Every emoji Telegram currently offers as a reaction, in its order.
    @ObservationIgnored private var activeEmojiReactions: [String] = []
    /// Telegram's own (approximate) count of chats in each list, to check that every chat arrived.
    @ObservationIgnored private var telegramChatCounts: [ChatListKind: Int] = [:]

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

    /// How many members a group has, or subscribers a channel.
    public func memberCount(of item: ChatItem) -> Int? {
        switch item.type {
        case .chatTypeBasicGroup(let group): basicGroupMemberCounts[group.basicGroupId]
        case .chatTypeSupergroup(let group): supergroupMemberCounts[group.supergroupId]
        default: nil
        }
    }

    /// Whether you can write in a chat. Only a channel's admins can post in it.
    public func canPost(in item: ChatItem) -> Bool {
        guard item.kind == .channel, case .chatTypeSupergroup(let channel) = item.type else { return true }
        return postableChannelIds.contains(channel.supergroupId)
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

    /// Whether the first-run "Choose Chats" sheet should open.
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
        case .group, .channel, .bot, .service: isShown ? .show : nil
        case .person, .savedMessages, .secret: isShown ? nil : .hide
        }
        visibility.setChoice(choice, for: item.id)
        scheduleRebuild()
    }

    /// What the "Choose Chats" sheet offers: every group, channel, bot and service chat, plus
    /// people you've hidden, most recently active first.
    public func chatsToChoose() -> [ChatItem] {
        items.values
            .filter { item in
                guard item.isIn(.main) || item.isIn(.archive) else { return false }
                switch item.kind {
                case .group, .channel, .bot, .service: return true
                case .person, .savedMessages, .secret: return visibility.choices[item.id] == .hide
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
        loadProblem = nil
        for list in [ChatListKind.main, .archive] {
            while self.client === client {
                do {
                    _ = try await client.loadChats(chatList: list.tdList, limit: 200)
                } catch let error as TDLibKit.Error where error.code == 404 {
                    break  // everything is loaded
                } catch let error as TDLibKit.Error where error.code == 429 {
                    // Telegram is pacing a big sync ("retry after N"): wait, then carry on.
                    let seconds = Self.retryAfter(error.message) ?? 5
                    Log.chats.notice("Telegram asked to wait \(seconds) s before sending more chats")
                    try? await Task.sleep(for: .seconds(min(seconds, 120)))
                } catch {
                    loadProblem = AuthModel.describe(error)
                    Log.chats.error("Loading chats failed: \(String(describing: error), privacy: .public)")
                    break
                }
            }
        }
        guard self.client === client else { return }
        isLoaded = true
        // TDLib's "all loaded" reply overtakes the updates still on their way, so wait for those
        // before counting.
        let start = ContinuousClock.now
        while self.client === client, ContinuousClock.now - start < .seconds(30) {
            let report = report()
            if let telegramMain = report.telegramMainCount, report.mainCount >= telegramMain,
               report.archiveCount >= report.telegramArchiveCount ?? 0 { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard self.client === client else { return }
        Log.chats.notice("""
            All chats in place \((ContinuousClock.now - start).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1))), privacy: .public) \
            after TDLib's reply. \(self.report().summary, privacy: .public)
            """)
        await findChatsTheListLeftOut(client: client)
    }

    /// Telegram's server can leave chats out of the list a new device downloads, even ones with
    /// messages from yesterday (a known Telegram bug: bugs.telegram.org/c/14753), and TDLib then
    /// never sends them. A chat asked for by itself comes back with its place in your list, so
    /// ask for every chat Telegram can name some other way: your contacts, the people and chats
    /// you use most, and everyone in your call history.
    private func findChatsTheListLeftOut(client: TDLibClient) async {
        let before = items.values.filter { $0.isIn(.main) || $0.isIn(.archive) }.count
        // TDLib looks up each chat it hasn't seen as these arrive.
        for category in [TopChatCategory.topChatCategoryUsers, .topChatCategoryCalls, .topChatCategoryGroups, .topChatCategoryChannels] {
            _ = try? await client.getTopChats(category: category, limit: 30)
        }
        var offset = ""
        for _ in 0..<3 {
            guard let calls = try? await client.searchCallMessages(limit: 100, offset: offset, onlyMissed: false),
                  !calls.nextOffset.isEmpty else { break }
            offset = calls.nextOffset
        }
        let contacts = (try? await client.getContacts())?.userIds ?? []
        // A one-on-one chat's id is the person's user id.
        let unknownContacts = contacts.filter { items[$0] == nil }
        for (index, userId) in unknownContacts.enumerated() {
            guard self.client === client else { return }
            // A steady pace keeps Telegram from asking us to slow down.
            if index > 0, index.isMultiple(of: 10) { try? await Task.sleep(for: .seconds(1)) }
            _ = try? await client.createPrivateChat(force: false, userId: userId)
        }
        try? await Task.sleep(for: .seconds(5))
        guard self.client === client else { return }
        let after = items.values.filter { $0.isIn(.main) || $0.isIn(.archive) }.count
        Log.chats.notice("""
            Found \(after - before) chats the downloaded list left out (checked top chats, call history \
            and \(unknownContacts.count) contacts). \(self.report().summary, privacy: .public)
            """)
    }

    /// Asks Telegram's servers for your chats matching a name, so a chat the downloaded list left
    /// out turns up when you search for it. Matches arrive through updates.
    public func searchServer(_ query: String) async {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let client else { return }
        _ = try? await client.searchChatsOnServer(limit: 20, query: query, typeFilter: nil)
    }

    /// The seconds in Telegram's "Too Many Requests: retry after 23".
    static func retryAfter(_ message: String) -> Int? {
        message.split(separator: " ").last.flatMap { Int($0) }
    }

    /// Where every chat went: shown, archived, hidden, or never in a list. For Settings → About,
    /// and for the log, when something seems missing.
    public func report() -> ChatListReport {
        var report = ChatListReport(isLoaded: isLoaded, loadProblem: loadProblem, knownChats: items.count)
        report.telegramMainCount = telegramChatCounts[.main]
        report.telegramArchiveCount = telegramChatCounts[.archive]
        for item in items.values {
            if item.isIn(.main) { report.mainCount += 1 }
            if item.isIn(.archive) { report.archiveCount += 1 }
            let placement = placement(of: item)
            switch item.kind {
            case .person, .savedMessages, .secret:
                switch placement {
                case .shown: report.peopleShown += 1
                case .archived: report.peopleArchived += 1
                case .hiddenByYou: report.peopleHiddenByYou += 1
                case .joinedTelegramOnly, .notPicked: report.peopleJoinedTelegramOnly += 1
                case .outsideLists: report.peopleOutsideLists += 1
                }
            case .group, .channel, .bot, .service:
                switch placement {
                case .outsideLists: continue
                case .shown, .archived: report.othersPicked += 1
                case .hiddenByYou, .joinedTelegramOnly, .notPicked:
                    if item.kind == .group {
                        report.groupsNotPicked += 1
                    } else if item.kind == .channel {
                        report.channelsNotPicked += 1
                    } else {
                        report.botsNotPicked += 1
                    }
                }
            }
        }
        return report
    }

    /// Where a chat went, and so whether the sidebar shows it.
    public func placement(of item: ChatItem) -> ChatPlacement {
        let inMain = item.isIn(.main)
        guard inMain || item.isIn(.archive) else { return .outsideLists }
        let choice = visibility.choices[item.id]
        if VisibilityPolicy.isVisible(summary(of: item), choice: choice) { return inMain ? .shown : .archived }
        if choice == .hide { return .hiddenByYou }
        return item.isJoinedTelegramStub ? .joinedTelegramOnly : .notPicked
    }

    /// Finds chats by name wherever they went, for when one seems to be missing. Also asks
    /// Telegram's servers, which finds chats this Mac was never told about.
    public func lookUp(_ query: String) async -> [ChatLookup] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let client else { return [] }
        let matches = { (item: ChatItem) in item.displayTitle.localizedStandardContains(query) }
        var results = items.values.filter(matches).map { ChatLookup(item: $0, placement: placement(of: $0), isFromServer: false) }
        let localIds = Set(results.map(\.item.id))
        let serverIds = (try? await client.searchChatsOnServer(limit: 20, query: query, typeFilter: nil))?.chatIds ?? []
        let newIds = serverIds.filter { !localIds.contains($0) }
        if !newIds.isEmpty {
            // TDLib looks up where each new chat belongs; give it a moment.
            try? await Task.sleep(for: .seconds(3))
        }
        for id in newIds {
            let item: ChatItem
            if let known = items[id] {
                item = known
            } else {
                // The reply can overtake the chat's own update, so read the chat directly.
                guard let chat = try? await client.resilientChat(id: id) else { continue }
                item = ChatItem(chat)
                item.kind = kind(of: item)
                refreshPreview(of: item)
            }
            results.append(ChatLookup(item: item, placement: placement(of: item), isFromServer: true))
        }
        results.sort { ($0.item.lastActivity ?? .distantPast) > ($1.item.lastActivity ?? .distantPast) }
        logLookup(results)
        return results
    }

    /// Where looked-up chats sit in the sidebar, now and a moment later, without names: whether a
    /// lookup moves a chat shows what kept it out of sight.
    private func logLookup(_ results: [ChatLookup]) {
        let ids = results.prefix(5).map(\.item.id)
        let fromServer = Set(results.filter(\.isFromServer).map(\.item.id))
        let describe = { [weak self] (moment: String) in
            guard let self else { return }
            for (index, id) in ids.enumerated() {
                let item = self.items[id]
                let row = self.mainList.firstIndex { $0.id == id }.map { "row \($0 + 1) of \(self.mainList.count)" } ?? "not in the sidebar"
                let age = item?.lastActivity.map { "\(Int(-$0.timeIntervalSinceNow / 86400)) d" } ?? "none"
                let order = item?.positions.first { $0.list == .chatListMain }?.order.rawValue ?? 0
                Log.chats.notice("""
                    Lookup \(moment, privacy: .public) #\(index + 1): \(item == nil ? "unknown" : "known", privacy: .public)\
                    \(fromServer.contains(id) ? ", found only on the server" : "", privacy: .public), \
                    \(item.map { self.placement(of: $0).description } ?? "-", privacy: .public), \(row, privacy: .public), \
                    kind \(String(describing: item?.kind), privacy: .public), last message \(age, privacy: .public) ago, \
                    order \(order, privacy: .public), title \(item.map { $0.title.isEmpty ? "empty" : "\($0.title.count) chars" } ?? "-", privacy: .public)
                    """)
            }
        }
        describe("now")
        Task {
            try? await Task.sleep(for: .seconds(4))
            describe("4 s later")
        }
    }

    func reset() {
        client = nil
        myUserId = nil
        items = [:]
        users = [:]
        directMessagesGroupIds = []
        postableChannelIds = []
        basicGroupMemberCounts = [:]
        supergroupMemberCounts = [:]
        scopeMuted = ScopeMuted()
        telegramChatCounts = [:]
        visibility.reset()
        loadProblem = nil
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
            if case .chatTypePrivate(let chat) = update.chat.type { item.presence = users[chat.userId]?.presence }
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
            let presence = isBot ? Presence.bot : Presence(user.status)
            users[user.id] = Person(
                id: user.id,
                firstName: user.firstName,
                lastName: user.lastName,
                accentColorId: user.accentColorId,
                photoFileId: user.profilePhoto?.small.id,
                isBot: isBot,
                presence: presence
            )
            setPresence(presence, forUser: user.id)
            if let photo = user.profilePhoto { files.apply(photo.small) }
            if previous?.isBot != isBot { scheduleRebuild() }
        case .updateUserStatus(let update):
            guard users[update.userId]?.isBot == false else { return }
            let presence = Presence(update.status)
            users[update.userId]?.presence = presence
            setPresence(presence, forUser: update.userId)
        case .updateBasicGroup(let update):
            basicGroupMemberCounts[update.basicGroup.id] = update.basicGroup.memberCount
        case .updateChatAvailableReactions(let update):
            items[update.chatId]?.availableReactions = update.availableReactions
        case .updateActiveEmojiReactions(let update):
            activeEmojiReactions = update.emojis
        case .updateUnreadChatCount(let update):
            switch update.chatList {
            case .chatListMain: telegramChatCounts[.main] = update.totalCount
            case .chatListArchive: telegramChatCounts[.archive] = update.totalCount
            case .chatListFolder: break
            }
        case .updateSupergroup(let update):
            let supergroup = update.supergroup
            supergroupMemberCounts[supergroup.id] = supergroup.memberCount
            if supergroup.isDirectMessagesGroup, directMessagesGroupIds.insert(supergroup.id).inserted {
                scheduleRebuild()
            }
            let canPost = switch supergroup.status {
            case .chatMemberStatusCreator: true
            case .chatMemberStatusAdministrator(let admin): admin.rights.canPostMessages
            default: false
            }
            if canPost { postableChannelIds.insert(supergroup.id) } else { postableChannelIds.remove(supergroup.id) }
        default:
            break
        }
    }

    /// A one-on-one chat's id is the person's user id.
    private func setPresence(_ presence: Presence, forUser userId: Int64) {
        guard let item = items[userId], item.presence != presence else { return }
        item.presence = presence
    }

    // MARK: Building the lists

    private func scheduleRebuild() {
        guard !isRebuildScheduled else { return }
        isRebuildScheduled = true
        // Coalesces the bursts of updates TDLib sends while loading (thousands at launch) into a
        // few rebuilds; rebuilding after each one keeps the list filling in for many seconds.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            self?.rebuild()
        }
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
    public internal(set) var presence: Presence

    /// Full name, or "Deleted Account" for accounts that no longer exist.
    public var name: String {
        let name = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? "Deleted Account" : name
    }
}

/// Where a chat went.
public enum ChatPlacement: Equatable, Sendable {
    case shown
    case archived
    case hiddenByYou
    /// Holds only "X joined Telegram".
    case joinedTelegramOnly
    /// A group, channel or bot you haven't picked.
    case notPicked
    /// In neither your chat list nor Archive on Telegram (deleted, or never started).
    case outsideLists

    public var description: String {
        switch self {
        case .shown: "In your chat list"
        case .archived: "In Archive (View → Show Archived Chats)"
        case .hiddenByYou: "Hidden by you"
        case .joinedTelegramOnly: "Hidden: it only holds “joined Telegram”"
        case .notPicked: "Hidden until you pick it in Choose Chats…"
        case .outsideLists: "Not in your Telegram chat list (deleted, or never started)"
        }
    }
}

/// A chat found by name, and where it went.
public struct ChatLookup: Identifiable {
    public let item: ChatItem
    public let placement: ChatPlacement
    /// Found only by asking Telegram's servers: this Mac's copy of the chat list lacked it.
    public let isFromServer: Bool

    public var id: Int64 { item.id }
}

/// Counts of where chats went, to explain a chat that seems to be missing.
public struct ChatListReport: Equatable, Sendable {
    public var isLoaded: Bool
    public var loadProblem: String?
    /// Every chat TDLib has told Hushh about, in a list or not.
    public var knownChats: Int
    /// Telegram's approximate count of chats in your list and in Archive.
    public var telegramMainCount: Int?
    public var telegramArchiveCount: Int?
    /// Chats of every kind Hushh has in your list and in Archive.
    public var mainCount = 0
    public var archiveCount = 0
    /// One-on-one chats (and Saved Messages) in the main list.
    public var peopleShown = 0
    /// One-on-one chats in Telegram's Archive: View → Show Archived Chats.
    public var peopleArchived = 0
    public var peopleHiddenByYou = 0
    /// Chats holding only "X joined Telegram".
    public var peopleJoinedTelegramOnly = 0
    /// Chats TDLib knows of that aren't in your chat list at all (deleted, or never started).
    public var peopleOutsideLists = 0
    public var othersPicked = 0
    public var groupsNotPicked = 0
    public var channelsNotPicked = 0
    public var botsNotPicked = 0

    public var summary: String {
        var lines = [
            isLoaded ? "Chat list fully loaded (\(knownChats) chats known)." : "Chat list still loading…",
            "One-on-one: \(peopleShown) in the list, \(peopleArchived) archived, \(peopleHiddenByYou) hidden by you, "
                + "\(peopleJoinedTelegramOnly) only “joined Telegram”, \(peopleOutsideLists) not in your chat list.",
            "Picked groups, channels and bots: \(othersPicked). Not picked: \(groupsNotPicked) groups, "
                + "\(channelsNotPicked) channels, \(botsNotPicked) bots.",
        ]
        if let telegramMainCount {
            lines.insert("Telegram counts about \(telegramMainCount) chats in your list and \(telegramArchiveCount ?? 0) in Archive; "
                + "Hushh has \(mainCount) and \(archiveCount).", at: 1)
        }
        if let loadProblem { lines.insert("Loading stopped early: \(loadProblem)", at: 1) }
        return lines.joined(separator: "\n")
    }
}
