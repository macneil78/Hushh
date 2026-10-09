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
    /// The chat open in the window. Its messages don't notify while Hush is in front.
    var openChatId: () -> Int64? = { nil }

    private let chats: ChatStore
    private let preferences: NotificationPreferences
    private var client: TDLibClient?
    private var center: UNUserNotificationCenter { .current() }

    private static let messageCategory = "message"
    private static let replyAction = "reply"
    private static let markReadAction = "mark-read"

    init(chats: ChatStore, preferences: NotificationPreferences) {
        self.chats = chats
        self.preferences = preferences
    }

    func start(session: TDSession) {
        client = session.client
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.messageCategory,
                actions: [
                    UNTextInputNotificationAction(
                        identifier: Self.replyAction, title: "Reply", options: [],
                        textInputButtonTitle: "Send", textInputPlaceholder: "Message"
                    ),
                    UNNotificationAction(identifier: Self.markReadAction, title: "Mark as Read", options: []),
                ],
                intentIdentifiers: [],
                options: []
            ),
        ])
        Task {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                Log.notifications.error("Notifications not allowed: \(String(describing: error), privacy: .public)")
            }
        }
        // TDLib produces no notifications until told how many groups it may keep.
        session.sendIgnoringReply(SetOption(name: "notification_group_count_max", value: .optionValueInteger(.init(value: 25))))
    }

    /// After logging out: forget the session and clear Notification Center.
    func reset() {
        guard client != nil else { return }
        client = nil
        center.removeAllDeliveredNotifications()
    }

    func handle(_ update: Update) {
        switch update {
        case .updateNotificationGroup(let group):
            if !group.removedNotificationIds.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: group.removedNotificationIds.map(Self.identifier))
            }
            for notification in group.addedNotifications {
                post(notification, chatId: group.chatId)
            }
        case .updateActiveNotifications(let active):
            // Sent at launch. Clear out anything TDLib no longer considers active (read while Hush
            // was closed), without re-alerting for what's still there.
            let activeIds = Set(active.groups.flatMap { $0.notifications.map { Self.identifier(for: $0.id) } })
            Task {
                let delivered = await center.deliveredNotifications().map(\.request.identifier)
                center.removeDeliveredNotifications(withIdentifiers: delivered.filter { !activeIds.contains($0) })
            }
        default:
            break
        }
    }

    private func post(_ notification: TDLibKit.Notification, chatId: Int64) {
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
            preview: new.showPreview && preferences.showsPreview ? MessagePreview.text(for: message.content) : nil,
            isSilent: notification.isSilent || !preferences.playsSound,
            chatId: chatId,
            messageId: message.id
        )
        let request = UNNotificationRequest(identifier: Self.identifier(for: notification.id), content: content, trigger: nil)
        center.add(request)
    }

    // MARK: Pure helpers

    static func identifier(for notificationId: Int) -> String {
        "notification-\(notificationId)"
    }

    /// Hidden chats never notify, and neither does the chat you're looking at.
    static func shouldNotify(isVisible: Bool, isOpenChat: Bool, isAppActive: Bool) -> Bool {
        isVisible && !(isOpenChat && isAppActive)
    }

    /// In groups the sender goes in the subtitle; without a preview (your Telegram privacy
    /// setting) the banner just says there's a new message.
    static func content(
        chatTitle: String,
        senderName: String?,
        preview: String?,
        isSilent: Bool,
        chatId: Int64,
        messageId: Int64
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = chatTitle
        if let senderName, !senderName.isEmpty { content.subtitle = senderName }
        content.body = preview ?? "New message"
        content.threadIdentifier = "chat-\(chatId)"
        content.categoryIdentifier = messageCategory
        content.userInfo = ["chatId": chatId, "messageId": messageId]
        if !isSilent { content.sound = .default }
        return content
    }

    // MARK: Responding

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
        let replyText = (response as? UNTextInputNotificationResponse)?.userText
        await respond(to: response.actionIdentifier, chatId: chatId, messageId: messageId, replyText: replyText)
    }

    private func respond(to action: String, chatId: Int64, messageId: Int64?, replyText: String?) {
        switch action {
        case Self.replyAction:
            guard let replyText, !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            send(replyText, to: chatId, readingUpTo: messageId)
        case Self.markReadAction:
            markRead(chatId: chatId, messageId: messageId)
        case UNNotificationDefaultActionIdentifier:
            NSApp.activate()
            onOpenChat?(chatId)
        default:
            break
        }
    }

    private func send(_ text: String, to chatId: Int64, readingUpTo messageId: Int64?) {
        guard let client else { return }
        Task {
            do {
                let formatted = try await client.parseMarkdown(text: FormattedText(entities: [], text: text))
                _ = try await client.sendMessage(
                    chatId: chatId,
                    inputMessageContent: .inputMessageText(InputMessageText(clearDraft: false, linkPreviewOptions: nil, text: formatted)),
                    options: nil, replyMarkup: nil, replyTo: nil, topicId: nil
                )
            } catch {
                Log.notifications.error("Reply from notification failed: \(String(describing: error), privacy: .public)")
            }
        }
        // Replying means you've read it, as in Telegram's own apps.
        markRead(chatId: chatId, messageId: messageId)
    }

    private func markRead(chatId: Int64, messageId: Int64?) {
        guard let client, let messageId else { return }
        Task {
            _ = try? await client.viewMessages(chatId: chatId, forceRead: true, messageIds: [messageId], source: .messageSourceNotification)
        }
    }
}
