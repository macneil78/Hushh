@preconcurrency import TDLibKit
import AppKit
import UserNotifications

/// Shows TDLib's notifications as macOS notifications, for visible chats only.
///
/// TDLib decides what deserves a notification: it applies Telegram's mute settings and removes
/// notifications once a message is read anywhere, including on your phone.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    /// Called when you click a notification.
    var onOpenChat: ((Int64) -> Void)?
    /// The chat you're looking at: open in the main window, while that window is in front. Its
    /// messages don't notify while Hush is active.
    var openChatId: () -> Int64? = { nil }

    private let chats: ChatStore
    private let preferences: NotificationPreferences
    private var client: TDLibClient?
    private let testCenter: (any NotificationPosting)?
    private var center: any NotificationPosting { testCenter ?? UNUserNotificationCenter.current() }
    /// The notifications TDLib considers active (shown, not yet read anywhere), by identifier.
    private var activeIds: Set<String> = []
    /// TDLib's notification groups, by id, and the chat each belongs to.
    private var groupChats: [Int: Int64] = [:]
    /// Clicks and replies that came before the chat list was ready, as when one launched Hush.
    private var pendingResponses: [Response] = []
    private var isReady = false

    static let messageCategory = "message"
    /// For chats you can't write in, such as channels: no Reply.
    static let readOnlyCategory = "message-read-only"
    static let replyAction = "reply"
    static let markReadAction = "mark-read"

    /// `center` is for tests; the app uses the system's Notification Center.
    init(chats: ChatStore, preferences: NotificationPreferences, center: (any NotificationPosting)? = nil) {
        self.chats = chats
        self.preferences = preferences
        testCenter = center
    }

    /// Must run before the app finishes launching: otherwise macOS never delivers the click or
    /// reply that launched Hush.
    func becomeDelegate() {
        // Notification Center exists only for an app bundle; a test process would crash here.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func start(session: TDSession) {
        client = session.client
        let markRead = UNNotificationAction(identifier: Self.markReadAction, title: "Mark as Read", options: [])
        center.register([
            UNNotificationCategory(
                identifier: Self.messageCategory,
                actions: [
                    UNTextInputNotificationAction(
                        identifier: Self.replyAction, title: "Reply", options: [],
                        textInputButtonTitle: "Send", textInputPlaceholder: "Message"
                    ),
                    markRead,
                ],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(identifier: Self.readOnlyCategory, actions: [markRead], intentIdentifiers: [], options: []),
        ])
        Task {
            do {
                try await center.requestAlertsAndSounds()
            } catch {
                Log.notifications.error("Notifications not allowed: \(String(describing: error), privacy: .public)")
            }
        }
        // TDLib produces no notifications until told how many groups it may keep.
        session.sendIgnoringReply(SetOption(name: "notification_group_count_max", value: .optionValueInteger(.init(value: 25))))
    }

    /// Call once the chat list has loaded: handles the clicks and replies that came before.
    func sessionIsReady() {
        isReady = true
        let pending = pendingResponses
        pendingResponses = []
        pending.forEach(handle)
    }

    /// After logging out: forget the session and clear Notification Center.
    func reset() {
        guard client != nil else { return }
        client = nil
        isReady = false
        pendingResponses = []
        activeIds = []
        groupChats = [:]
        center.removeAll()
    }

    func handle(_ update: Update) {
        switch update {
        case .updateNotificationGroup(let group):
            groupChats[group.notificationGroupId] = group.chatId
            if !group.removedNotificationIds.isEmpty {
                let removed = group.removedNotificationIds.map(Self.identifier)
                activeIds.subtract(removed)
                center.remove(removed)
            }
            for notification in group.addedNotifications {
                activeIds.insert(Self.identifier(for: notification.id))
                post(notification, chatId: group.chatId)
            }
        case .updateNotification(let change):
            // A message was edited: replace its notification's text, if it's still shown.
            guard let chatId = groupChats[change.notificationGroupId] else { break }
            let identifier = Self.identifier(for: change.notification.id)
            Task {
                guard await center.deliveredIdentifiers().contains(identifier), activeIds.contains(identifier) else { return }
                post(change.notification, chatId: chatId, isEdit: true)
            }
        case .updateActiveNotifications(let active):
            // Sent at launch. Clear out anything TDLib no longer considers active (read while Hush
            // was closed), without re-alerting for what's still there.
            for group in active.groups {
                groupChats[group.id] = group.chatId
                activeIds.formUnion(group.notifications.map { Self.identifier(for: $0.id) })
            }
            Task {
                let delivered = await center.deliveredIdentifiers()
                // Checked after the wait: notifications posted meanwhile are active too.
                center.remove(delivered.filter { $0.hasPrefix(Self.identifierPrefix) && !activeIds.contains($0) })
            }
        default:
            break
        }
    }

    private func post(_ notification: TDLibKit.Notification, chatId: Int64, isEdit: Bool = false) {
        guard preferences.isEnabled,
              case .notificationTypeNewMessage(let new) = notification.type,
              let chat = chats.item(chatId),
              Self.shouldNotify(
                isVisible: chats.isVisible(chatId),
                isOpenChat: chatId == openChatId(),
                isAppActive: NSApp.isActive
              )
        else { return }
        let message = new.message
        let senderName: String = switch message.senderId {
        case .messageSenderUser(let user): chats.person(user.userId)?.name ?? ""
        case .messageSenderChat(let sender): chats.item(sender.chatId)?.title ?? ""
        }
        let content = Self.content(
            chatTitle: chat.displayTitle,
            senderName: chat.kind == .group ? senderName : nil,
            preview: new.showPreview && preferences.showsPreview ? MessagePreview.text(for: message.content, selfDestructs: message.selfDestructType != nil) : nil,
            // An edit replaces the text quietly.
            isSilent: isEdit || notification.isSilent || !preferences.playsSound,
            chatId: chatId,
            messageId: message.id,
            canReply: chats.canPost(in: chat),
            isGroup: chat.kind == .group
        )
        // The same identifier replaces a delivered notification.
        center.post(UNNotificationRequest(identifier: Self.identifier(for: notification.id), content: content, trigger: nil))
    }

    // MARK: Pure helpers

    private static let identifierPrefix = "notification-"

    static func identifier(for notificationId: Int) -> String {
        identifierPrefix + String(notificationId)
    }

    /// Hidden chats never notify, and neither does the chat you're looking at.
    static func shouldNotify(isVisible: Bool, isOpenChat: Bool, isAppActive: Bool) -> Bool {
        isVisible && !(isOpenChat && isAppActive)
    }

    /// In groups the sender goes in the subtitle; without a preview (your Telegram privacy
    /// setting) the banner just says there's a new message. Reply is offered only where you can
    /// write.
    static func content(
        chatTitle: String,
        senderName: String?,
        preview: String?,
        isSilent: Bool,
        chatId: Int64,
        messageId: Int64,
        canReply: Bool = true,
        isGroup: Bool = false
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = chatTitle
        if let senderName, !senderName.isEmpty { content.subtitle = senderName }
        content.body = preview ?? "New message"
        content.threadIdentifier = "chat-\(chatId)"
        content.categoryIdentifier = canReply ? messageCategory : readOnlyCategory
        content.userInfo = ["chatId": chatId, "messageId": messageId, "isGroup": isGroup]
        if !isSilent { content.sound = .default }
        return content
    }

    /// Says a reply from a notification didn't go out. Clicking it opens the chat, where the
    /// text waits as a draft. It never repeats the text: others may see the screen.
    static func failedReplyContent(chatTitle: String?, reason: String?, isKeptAsDraft: Bool, chatId: Int64) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Your reply wasn't sent"
        if let chatTitle { content.subtitle = chatTitle }
        // No reason for errors TDLib says must not be shown (code 406).
        content.body = (isKeptAsDraft ? "It's saved as a draft in the chat. " : "") + (reason.map { "Telegram said: \($0)" } ?? "")
        content.threadIdentifier = "chat-\(chatId)"
        content.userInfo = ["chatId": chatId]
        content.sound = .default
        return content
    }

    // MARK: Responding

    struct Response {
        let action: String
        let chatId: Int64
        let messageId: Int64?
        let replyText: String?
        let isGroup: Bool
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Hush is in front: no banner over what you're doing, just the sound and an entry in
        // Notification Center. The sidebar already shows what's new.
        [.list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let chatId = (userInfo["chatId"] as? NSNumber)?.int64Value else { return }
        let messageId = (userInfo["messageId"] as? NSNumber)?.int64Value
        let isGroup = (userInfo["isGroup"] as? NSNumber)?.boolValue ?? false
        let replyText = (response as? UNTextInputNotificationResponse)?.userText
        await respond(Response(action: response.actionIdentifier, chatId: chatId, messageId: messageId, replyText: replyText, isGroup: isGroup))
    }

    /// Acts on a click or a reply, or keeps it until the chat list is ready.
    func respond(_ response: Response) {
        guard isReady else {
            pendingResponses.append(response)
            return
        }
        handle(response)
    }

    private func handle(_ response: Response) {
        switch response.action {
        case Self.replyAction:
            guard let text = response.replyText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            send(text, to: response.chatId, answering: response.messageId, isGroup: response.isGroup)
        case Self.markReadAction:
            markRead(chatId: response.chatId, messageId: response.messageId)
        case UNNotificationDefaultActionIdentifier:
            onOpenChat?(response.chatId)
        default:
            break
        }
    }

    private func send(_ text: String, to chatId: Int64, answering messageId: Int64?, isGroup: Bool) {
        guard let client else { return }
        // In a group, answer the message you replied to, so it's clear what you mean.
        let answering = isGroup ? messageId : nil
        Task {
            do {
                let formatted = try await client.parseMarkdown(text: FormattedText(entities: [], text: text))
                _ = try await client.sendMessage(
                    chatId: chatId,
                    inputMessageContent: .inputMessageText(InputMessageText(clearDraft: false, linkPreviewOptions: nil, text: formatted)),
                    options: nil, replyMarkup: nil, replyTo: Self.replyTo(answering), topicId: nil
                )
                // Replying means you've read it, as in Telegram's own apps. A reply that failed
                // leaves the chat unread, so you come back to it.
                markRead(chatId: chatId, messageId: messageId)
            } catch {
                Log.notifications.error("Reply from notification failed: \(String(describing: error), privacy: .public)")
                await replyFailed(text, chatId: chatId, answering: answering, error: error)
            }
        }
    }

    /// Keeps what you wrote as the chat's draft (after any draft already there) and says so.
    private func replyFailed(_ text: String, chatId: Int64, answering messageId: Int64?, error: any Swift.Error) async {
        let earlier = chats.item(chatId)?.rawDraft ?? ""
        let draft = earlier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : earlier + "\n\n" + text
        var isKept = false
        if let client {
            do {
                _ = try await client.setChatDraftMessage(chatId: chatId, draftMessage: Self.draftMessage(draft, answering: messageId), topicId: nil)
                isKept = true
            } catch {
                Log.notifications.error("Couldn't keep a failed reply as a draft: \(String(describing: error), privacy: .public)")
            }
        }
        let content = Self.failedReplyContent(
            chatTitle: chats.item(chatId)?.displayTitle, reason: AuthModel.describe(error), isKeptAsDraft: isKept, chatId: chatId
        )
        center.post(UNNotificationRequest(identifier: "reply-failed-\(chatId)", content: content, trigger: nil))
    }

    private nonisolated static func draftMessage(_ text: String, answering messageId: Int64?) -> DraftMessage {
        DraftMessage(
            content: .draftMessageContentText(DraftMessageContentText(linkPreviewOptions: nil, text: FormattedText(entities: [], text: text))),
            date: Int(Foundation.Date.now.timeIntervalSince1970),
            effectId: 0,
            replyTo: replyTo(messageId),
            suggestedPostInfo: nil
        )
    }

    // Nonisolated, so the TDLib value it builds can be handed to TDLib's background queues.
    private nonisolated static func replyTo(_ messageId: Int64?) -> InputMessageReplyTo? {
        messageId.map {
            .inputMessageReplyToMessage(InputMessageReplyToMessage(checklistTaskId: 0, messageId: $0, pollOptionId: "", quote: nil))
        }
    }

    private func markRead(chatId: Int64, messageId: Int64?) {
        guard let client, let messageId else { return }
        Task {
            _ = try? await client.viewMessages(chatId: chatId, forceRead: true, messageIds: [messageId], source: .messageSourceNotification)
        }
    }
}

/// The parts of Notification Center the service uses. Tests stand in for it: the real one needs
/// an app bundle.
@MainActor
protocol NotificationPosting: AnyObject {
    func post(_ request: UNNotificationRequest)
    func remove(_ identifiers: [String])
    func removeAll()
    func deliveredIdentifiers() async -> [String]
    func register(_ categories: Set<UNNotificationCategory>)
    func requestAlertsAndSounds() async throws
}

extension UNUserNotificationCenter: NotificationPosting {
    func post(_ request: UNNotificationRequest) {
        add(request)
    }

    func remove(_ identifiers: [String]) {
        removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func removeAll() {
        removeAllDeliveredNotifications()
    }

    func deliveredIdentifiers() async -> [String] {
        await deliveredNotifications().map(\.request.identifier)
    }

    func register(_ categories: Set<UNNotificationCategory>) {
        setNotificationCategories(categories)
    }

    func requestAlertsAndSounds() async throws {
        _ = try await requestAuthorization(options: [.alert, .sound])
    }
}
