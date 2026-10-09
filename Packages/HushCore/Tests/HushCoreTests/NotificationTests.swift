import Foundation
import Testing
@testable import HushCore

@MainActor
struct NotificationTests {
    @Test func hiddenChatsAndTheChatYoureReadingStayQuiet() {
        #expect(NotificationService.shouldNotify(isVisible: true, isOpenChat: false, isAppActive: true))
        #expect(!NotificationService.shouldNotify(isVisible: false, isOpenChat: false, isAppActive: false))
        #expect(!NotificationService.shouldNotify(isVisible: true, isOpenChat: true, isAppActive: true))
        // Open in the window, but you're in another app: you'd want to know.
        #expect(NotificationService.shouldNotify(isVisible: true, isOpenChat: true, isAppActive: false))
    }

    @Test func groupBannersNameTheSender() {
        let content = NotificationService.content(
            chatTitle: "Climbing", senderName: "Alex", preview: "Saturday?", isSilent: false, chatId: -100, messageId: 5
        )
        #expect(content.title == "Climbing")
        #expect(content.subtitle == "Alex")
        #expect(content.body == "Saturday?")
        #expect(content.threadIdentifier == "chat--100")
        #expect(content.sound != nil)
        #expect((content.userInfo["chatId"] as? NSNumber)?.int64Value == -100)
        #expect((content.userInfo["messageId"] as? NSNumber)?.int64Value == 5)
    }

    @Test func withoutAPreviewTheBannerIsGeneric() {
        let content = NotificationService.content(
            chatTitle: "Sam", senderName: nil, preview: nil, isSilent: true, chatId: 42, messageId: 7
        )
        #expect(content.subtitle.isEmpty)
        #expect(content.body == "New message")
        #expect(content.sound == nil)
    }
}

@MainActor
struct NotificationPreferencesTests {
    @Test func defaultToOnAndRemember() throws {
        let suite = "hush-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = NotificationPreferences(defaults: defaults)
        #expect(preferences.isEnabled && preferences.playsSound && preferences.showsPreview)

        preferences.showsPreview = false
        preferences.playsSound = false
        let reloaded = NotificationPreferences(defaults: defaults)
        #expect(reloaded.isEnabled)
        #expect(!reloaded.playsSound)
        #expect(!reloaded.showsPreview)
    }
}
