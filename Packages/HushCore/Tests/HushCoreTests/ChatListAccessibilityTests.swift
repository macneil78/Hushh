import AppKit
import Foundation
import SwiftUI
import Testing
@preconcurrency import TDLibKit
@testable import HushCore
@testable import HushUI

/// What VoiceOver reads for the sidebar's rows.
@MainActor
@Suite(.serialized)
struct ChatRowAccessibilityTests {
    @Test func rowsSayWhatTheDotsAndIconsShow() async throws {
        let store = Fixtures.store()
        let now = Int(Date().timeIntervalSince1970)
        store.handle(.updateUser(.init(user: Fixtures.user(1, "Anna", "Petrova", status: .userStatusOnline(.init(expires: now + 300))))))
        store.handle(.updateNewChat(.init(chat: Fixtures.chat(
            1, "Anna Petrova", positions: [Fixtures.position(9_000, pinned: true)],
            last: Fixtures.message(1, Fixtures.text("Are you coming tonight?"), chat: 1, date: now - 60), unread: 2
        ))))
        store.handle(.updateNewChat(.init(chat: Fixtures.chat(
            2, "Max", positions: [Fixtures.position(800)], last: Fixtures.message(2, Fixtures.text("ok"), chat: 2, date: now - 120),
            unread: 4, notification: Fixtures.notificationSettings(muteFor: 999_999, useDefault: false)
        ))))
        store.handle(.updateNewChat(.init(chat: Fixtures.chat(
            -3, "Tech News", type: Fixtures.channel(3), positions: [Fixtures.position(700)],
            last: Fixtures.message(3, Fixtures.text("New MacBook"), chat: -3, date: now - 180)
        ))))
        store.setShown(true, for: store.item(-3)!)
        await Fixtures.settle()

        struct Sidebar: View {
            let store: ChatStore
            var body: some View {
                List {
                    ForEach(store.mainList) { ChatRow(item: $0, files: FileStore(), list: .main, isSelected: false) }
                }
                .listStyle(.sidebar)
            }
        }
        TestWindow.enableAccessibility()
        let window = TestWindow.host(Sidebar(store: store), width: 320, height: 400)
        defer { TestWindow.close(window) }
        await TestWindow.settle()
        // SwiftUI builds the tree when it is first asked for it.
        _ = TestWindow.accessibilityTree(of: window.contentView!)
        await TestWindow.settle()
        let tree = TestWindow.accessibilityTree(of: window.contentView!)
        let anna = try #require(tree.split(separator: "\n").first { $0.contains("Anna Petrova") }, "\(tree)")
        for state in ["unread", "online", "pinned", "Are you coming tonight?"] {
            #expect(anna.contains(state), "Anna's row doesn't say '\(state)': \(anna)")
        }
        let max = try #require(tree.split(separator: "\n").first { $0.contains("Max") })
        #expect(max.contains("unread") && max.contains("muted"), "\(max)")
        #expect(tree.contains("Tech News, channel"), "\(tree)")
        #expect(!tree.contains("\"AP\"") && !tree.contains("megaphone"), "initials or a raw symbol name are read: \(tree)")
    }
}

/// The sidebar's search looks in one list; when nothing there matches, it says where the chat is.
@MainActor
@Suite(.serialized)
struct ChatListSearchHintTests {
    private func emptySearch(_ text: String, model: AppModel) async -> String {
        let state = WindowState()
        state.searchText = text
        TestWindow.enableAccessibility()
        let window = TestWindow.host(ChatListView(model: model, window: state), width: 320, height: 500)
        defer { TestWindow.close(window) }
        await TestWindow.settle()
        return TestWindow.accessibilityTree(of: window.contentView!)
    }

    @Test func noResultsPointsToArchivedAndHiddenChats() async {
        let model = AppModel(configuration: nil)
        model.chats.handle(.updateNewChat(.init(chat: Fixtures.chat(1, "Anna", positions: [Fixtures.position(10)]))))
        model.chats.handle(.updateNewChat(.init(chat: Fixtures.chat(2, "Bob", positions: [Fixtures.position(10, list: .chatListArchive)]))))
        model.chats.handle(.updateNewChat(.init(chat: Fixtures.chat(-3, "Book Club", type: Fixtures.basicGroup(3), positions: [Fixtures.position(9)]))))
        await Fixtures.settle()

        let archived = await emptySearch("bob", model: model)
        #expect(archived.contains("Show 1 in Archived Chats"), "\(archived)")
        let hidden = await emptySearch("book", model: model)
        #expect(hidden.contains("“Book Club” is hidden"), "\(hidden)")
        // No chat list was loaded here, so a search with no match anywhere is still going.
        let nothing = await emptySearch("zzz", model: model)
        #expect(nothing.contains("Searching…"), "\(nothing)")
    }
}
