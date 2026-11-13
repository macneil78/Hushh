import AppKit
import Foundation
import Testing
import UserNotifications
@preconcurrency import TDLibKit
@testable import HushCore

/// Notification Center as the service sees it, in memory.
@MainActor
private final class FakeNotificationCenter: NotificationPosting {
    private(set) var delivered: [String: UNNotificationRequest] = [:]
    private(set) var posted: [UNNotificationRequest] = []
    private(set) var removed: [String] = []

    func post(_ request: UNNotificationRequest) {
        posted.append(request)
        delivered[request.identifier] = request
    }

    func remove(_ identifiers: [String]) {
        removed += identifiers
        identifiers.forEach { delivered[$0] = nil }
    }

    func removeAll() { delivered = [:] }
    func deliveredIdentifiers() async -> [String] { Array(delivered.keys) }
    func register(_ categories: Set<UNNotificationCategory>) {}
    func requestAlertsAndSounds() async throws {}

    /// A notification left over from an earlier launch.
    func deliver(_ identifier: String) {
        delivered[identifier] = UNNotificationRequest(identifier: identifier, content: UNNotificationContent(), trigger: nil)
    }
}

/// Banners for new messages, edits and replies, posted to a Notification Center in memory.
@MainActor
struct NotificationServiceTests {
    /// `post` reads NSApp.isActive; the test process is never active.
    private static let app: Void = { NSApplication.shared.setActivationPolicy(.prohibited) }()

    private let alex: Int64 = 7
    private let news: Int64 = -1005
    private let climbing: Int64 = -200

    private func makeService() -> (NotificationService, FakeNotificationCenter) {
        _ = Self.app
        let chats = ChatStore(files: FileStore())
        chats.handle(.updateNewChat(.init(chat: Fixtures.chat(alex, "Alex", positions: [Fixtures.position(3)]))))
        chats.handle(.updateNewChat(.init(chat: Fixtures.chat(news, "News", type: Fixtures.channel(5), positions: [Fixtures.position(2)]))))
        chats.handle(.updateNewChat(.init(chat: Fixtures.chat(climbing, "Climbing", type: Fixtures.basicGroup(200), positions: [Fixtures.position(1)]))))
        for id in [news, climbing] { chats.setShown(true, for: chats.item(id)!) }
        let suite = "hushh-test-\(UUID().uuidString)"
        let center = FakeNotificationCenter()
        let service = NotificationService(chats: chats, preferences: NotificationPreferences(defaults: UserDefaults(suiteName: suite)!), center: center)
        return (service, center)
    }

    private func notification(_ id: Int, chatId: Int64, text: String) -> TDLibKit.Notification {
        let message = Fixtures.message(Int64(id) * 10, Fixtures.text(text), chat: chatId, from: alex, date: 1_760_000_000)
        return TDLibKit.Notification(date: 1_760_000_000, id: id, isSilent: false, type: .notificationTypeNewMessage(.init(message: message, showPreview: true)))
    }

    private func group(_ id: Int, chatId: Int64, added: [TDLibKit.Notification] = [], removed: [Int] = []) -> Update {
        .updateNotificationGroup(.init(
            addedNotifications: added, chatId: chatId, notificationGroupId: id, notificationSettingsChatId: chatId,
            notificationSoundId: 0, removedNotificationIds: removed, totalCount: added.count, type: .notificationGroupTypeMessages
        ))
    }

    @Test func startUpCleanUpKeepsWhatArrivedMeanwhile() async {
        let (service, center) = makeService()
        center.deliver("notification-1")  // read on the phone while Hush was closed
        center.deliver("notification-2")  // still unread
        service.handle(.updateActiveNotifications(.init(groups: [
            NotificationGroup(chatId: alex, id: 10, notifications: [notification(2, chatId: alex, text: "hi")], totalCount: 1, type: .notificationGroupTypeMessages),
        ])))
        // A message that came while Hush was closed, posted before the clean-up has looked.
        service.handle(group(10, chatId: alex, added: [notification(3, chatId: alex, text: "are you there?")]))
        await Fixtures.wait { !center.removed.isEmpty }
        #expect(center.removed == ["notification-1"])
        #expect(Set(center.delivered.keys) == ["notification-2", "notification-3"])
    }

    @Test func anEditReplacesTheTextQuietlyIfStillShown() async {
        let (service, center) = makeService()
        service.handle(group(10, chatId: alex, added: [notification(5, chatId: alex, text: "Saturday?"), notification(6, chatId: alex, text: "or")]))
        center.remove(["notification-6"])  // you dismissed this one
        service.handle(.updateNotification(.init(notification: notification(5, chatId: alex, text: "Sunday?"), notificationGroupId: 10)))
        service.handle(.updateNotification(.init(notification: notification(6, chatId: alex, text: "or Monday"), notificationGroupId: 10)))
        await Fixtures.wait { center.posted.count > 2 }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(center.posted.count == 3)
        #expect(center.delivered["notification-5"]?.content.body == "Sunday?")
        #expect(center.delivered["notification-5"]?.content.sound == nil)
        #expect(center.delivered["notification-6"] == nil)
    }

    @Test func noReplyWhereYouCantWrite() {
        let (service, center) = makeService()
        service.handle(group(10, chatId: news, added: [notification(1, chatId: news, text: "Headline")]))
        service.handle(group(11, chatId: alex, added: [notification(2, chatId: alex, text: "hi")]))
        service.handle(group(12, chatId: climbing, added: [notification(3, chatId: climbing, text: "Saturday?")]))
        #expect(center.posted.map(\.content.categoryIdentifier) == [
            NotificationService.readOnlyCategory, NotificationService.messageCategory, NotificationService.messageCategory,
        ])
        #expect(center.posted.map { $0.content.userInfo["isGroup"] as? Bool } == [false, false, true])
    }

    /// A reply typed in a notification that launched Hush waits for the session, is sent, and
    /// when it fails (here: TDLib isn't logged in) you hear about it.
    @Test func aReplyThatLaunchedHushIsSentOnceReadyAndAFailureIsReported() async {
        let (service, center) = makeService()
        var opened: [Int64] = []
        service.onOpenChat = { opened.append($0) }
        service.respond(.init(action: UNNotificationDefaultActionIdentifier, chatId: alex, messageId: 20, replyText: nil, isGroup: false))
        service.respond(.init(action: NotificationService.replyAction, chatId: climbing, messageId: 30, replyText: "On my way", isGroup: true))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(opened.isEmpty && center.posted.isEmpty)

        let session = TDSession()
        service.start(session: session)
        service.sessionIsReady()
        #expect(opened == [alex])
        await Fixtures.wait { !center.posted.isEmpty }
        let failure = center.posted.first
        #expect(failure?.identifier == "reply-failed-\(climbing)")
        #expect(failure?.content.title == "Your reply wasn't sent")
        #expect(failure?.content.subtitle == "Climbing")
        #expect(failure?.content.categoryIdentifier == "")  // no Reply on the failure itself
        #expect((failure?.content.userInfo["chatId"] as? NSNumber)?.int64Value == climbing)
        service.reset()
        _ = try? await session.client.close()
    }
}
