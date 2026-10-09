import Foundation
import Testing
@preconcurrency import TDLibKit
@testable import HushCore

struct ChatClassificationTests {
    private func kind(_ type: ChatType, chatId: Int64 = 1) -> ChatKind {
        ChatKind.classify(
            type,
            chatId: chatId,
            myUserId: 10,
            serviceChatId: 777000,
            isBot: { $0 == 20 },
            isDirectMessagesGroup: { $0 == 30 }
        )
    }

    @Test func privateChats() {
        #expect(kind(.chatTypePrivate(.init(userId: 10)), chatId: 10) == .savedMessages)
        #expect(kind(.chatTypePrivate(.init(userId: 777000)), chatId: 777000) == .service)
        #expect(kind(.chatTypePrivate(.init(userId: 20)), chatId: 20) == .bot)
        #expect(kind(.chatTypePrivate(.init(userId: 21)), chatId: 21) == .person)
        #expect(kind(.chatTypeSecret(.init(secretChatId: 1, userId: 21))) == .secret)
    }

    @Test func groupsAndChannels() {
        #expect(kind(.chatTypeBasicGroup(.init(basicGroupId: 5))) == .group)
        #expect(kind(.chatTypeSupergroup(.init(isChannel: false, supergroupId: 6))) == .group)
        #expect(kind(.chatTypeSupergroup(.init(isChannel: true, supergroupId: 7))) == .channel)
        // A channel's direct-messages group counts as the channel.
        #expect(kind(.chatTypeSupergroup(.init(isChannel: false, supergroupId: 30))) == .channel)
    }
}

struct MessagePreviewTests {
    private func text(_ string: String) -> MessageContent {
        .messageText(MessageText(linkPreview: nil, linkPreviewOptions: nil, text: FormattedText(entities: [], text: string)))
    }

    @Test func textIsFlattenedToOneLine() {
        #expect(MessagePreview.text(for: text("Hi\nthere\n\nfriend")) == "Hi there friend")
    }

    @Test func joinedTelegramNotice() {
        #expect(MessagePreview.text(for: .messageContactRegistered) == "Joined Telegram")
    }
}

@MainActor
struct VisibilitySettingsTests {
    @Test func choicesSurviveARelaunch() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "hush-tests-\(UUID().uuidString)/visibility.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let settings = VisibilitySettings()
        settings.load(from: file)
        #expect(settings.choices.isEmpty)
        #expect(!settings.hasChosenGroupsAndBots)

        settings.setChoice(.show, for: -1_001_234_567_890)
        settings.setChoice(.hide, for: 42)
        settings.markChosen()

        let reloaded = VisibilitySettings()
        reloaded.load(from: file)
        #expect(reloaded.choices == [-1_001_234_567_890: .show, 42: .hide])
        #expect(reloaded.hasChosenGroupsAndBots)

        reloaded.setChoice(nil, for: 42)
        let again = VisibilitySettings()
        again.load(from: file)
        #expect(again.choices == [-1_001_234_567_890: .show])
    }
}
