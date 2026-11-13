import AppKit
import Foundation
import SwiftUI
import Testing
@preconcurrency import TDLibKit
@testable import HushCore
@testable import HushUI

/// The first-run "Choose Chats" sheet, on a first sync where chats keep arriving.
@MainActor
@Suite(.serialized)
struct ChooseChatsTests {
    /// A group that arrives while the sheet is open gets a row, at the end; nothing reshuffles,
    /// and a hidden person switched back on keeps their row.
    @Test func sheetAddsChatsThatArriveLate() async throws {
        let store = Fixtures.store()
        store.handle(.updateNewChat(.init(chat: Fixtures.chat(-1, "Book Club", type: Fixtures.basicGroup(1), positions: [Fixtures.position(10)]))))
        store.handle(.updateNewChat(.init(chat: Fixtures.chat(30, "Ex", positions: [Fixtures.position(20)]))))
        store.setShown(false, for: store.item(30)!)
        await Fixtures.settle()

        TestWindow.enableAccessibility()
        let window = TestWindow.host(ChooseChatsView(chats: store, files: FileStore()), width: 480, height: 600)
        defer { TestWindow.close(window) }
        let content = try #require(window.contentView)
        await TestWindow.settle()
        _ = TestWindow.accessibilityTree(of: content)
        await Fixtures.wait { TestWindow.accessibilityTree(of: content).contains("Book Club") }
        #expect(TestWindow.accessibilityTree(of: content).contains("Book Club"))
        store.setShown(true, for: store.item(30)!)
        store.handle(.updateNewChat(.init(chat: Fixtures.chat(-2, "Climbing Crew", type: Fixtures.supergroup(2), positions: [Fixtures.position(5)]))))
        // Redrawn on the main run loop; on a busy machine that can take a few passes.
        var tree = ""
        for _ in 0 ..< 20 {
            await TestWindow.settle(0.25)
            tree = TestWindow.accessibilityTree(of: content)
            if tree.contains("Climbing Crew") && tree.contains("Ex") { break }
        }
        let late = try #require(tree.range(of: "Climbing Crew"), "the late group has no row:\n\(tree)")
        let early = try #require(tree.range(of: "Book Club"))
        #expect(early.lowerBound < late.lowerBound)
        #expect(tree.contains("Ex"), "the person switched back on lost their row")
    }

    /// TDLib's "all loaded" reply comes before the chats it counted. The sheet opens when
    /// `isLoaded` turns true, so that must wait for them.
    @Test func loadedOnlyOnceTheCountedChatsArrived() async throws {
        let session = TDSession()
        let store = ChatStore(files: FileStore())
        let file = FileManager.default.temporaryDirectory.appending(path: "hush-test-\(UUID().uuidString)/visibility.json")
        store.attach(client: session.client, myUserId: Fixtures.me, settingsFile: file)
        store.handle(.updateUnreadChatCount(.init(
            chatList: .chatListMain, markedAsUnreadCount: 0, markedAsUnreadUnmutedCount: 0,
            totalCount: 2, unreadCount: 0, unreadUnmutedCount: 0
        )))
        store.handle(.updateUnreadChatCount(.init(
            chatList: .chatListArchive, markedAsUnreadCount: 0, markedAsUnreadUnmutedCount: 0,
            totalCount: 0, unreadCount: 0, unreadUnmutedCount: 0
        )))
        store.handle(.updateNewChat(.init(chat: Fixtures.chat(1, "Anna", positions: [Fixtures.position(1)]))))
        // Without a login TDLib answers loadChats at once with an error, like a finished load.
        let loading = Task { await store.loadLists() }
        try? await Task.sleep(for: .milliseconds(600))
        #expect(!store.isLoaded, "loaded with one of two chats in")
        #expect(!store.shouldOfferChoosing)

        store.handle(.updateNewChat(.init(chat: Fixtures.chat(-2, "Book Club", type: Fixtures.basicGroup(2), positions: [Fixtures.position(2)]))))
        try? await Task.sleep(for: .milliseconds(600))
        #expect(store.isLoaded)
        #expect(store.shouldOfferChoosing)
        #expect(store.chatsToChoose().map(\.title) == ["Book Club"])

        store.reset()
        loading.cancel()
        _ = try? await session.client.close()
    }
}
