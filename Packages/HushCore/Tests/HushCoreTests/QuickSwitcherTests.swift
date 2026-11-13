import Carbon.HIToolbox
import Foundation
import Testing
@testable import HushCore
@testable import HushUI

/// ⌘K's order decides which chat Enter opens; the sidebar search and Choose Chats find names
/// the same way.
struct NameMatchTests {
    /// The names in `list` that `query` finds, best first; `list` is in Telegram's order.
    private func ranked(_ query: String, _ list: [String]) -> [String] {
        NameMatch(query)?.ranked(list, name: { $0 }) ?? list
    }

    @Test func accentedNameStartingWithTheQueryComesFirst() {
        #expect(ranked("emile", ["Bob Emile", "Émile Zola"]) == ["Émile Zola", "Bob Emile"])
    }

    @Test func wordStartBeatsTheMiddleOfAWord() {
        #expect(ranked("smi", ["Cosmic Club", "John Smith"]) == ["John Smith", "Cosmic Club"])
        #expect(ranked("an", ["Bob Anderson", "Joanna", "Anna"]) == ["Anna", "Bob Anderson", "Joanna"])
    }

    @Test func latinFindsCyrillicAndBack() {
        #expect(ranked("ivan", ["Иван Петров", "Bob"]) == ["Иван Петров"])
        #expect(ranked("petr", ["Иван Петров"]) == ["Иван Петров"])
        #expect(ranked("vsev", ["Всеволод"]) == ["Всеволод"])
        #expect(ranked("иван", ["Ivan Petrov"]) == ["Ivan Petrov"])
        // х both ways; ж, ш and я as names are usually written in Latin.
        #expect(ranked("mikhail", ["Михаил"]) == ["Михаил"])
        #expect(ranked("mihail", ["Михаил"]) == ["Михаил"])
        #expect(ranked("zhenya", ["Женя"]) == ["Женя"])
        #expect(ranked("sasha", ["Саша"]) == ["Саша"])
        #expect(ranked("aleksey", ["Алексей"]) == ["Алексей"])
    }

    @Test func emptyQueryAndNoMatch() {
        #expect(NameMatch("  ") == nil)
        #expect(ranked("zzz", ["A", "B"]).isEmpty)
        #expect(ranked("😀", ["Party 😀", "B"]) == ["Party 😀"])
    }
}

/// The real ⌘K view, typed into and confirmed with Enter, in a window nobody sees.
@MainActor
@Suite(.serialized)
struct QuickSwitcherTests {
    final class Picked { var title: String? }

    /// Opens ⌘K over chats in this order, types `query`, presses Enter; returns what opened.
    private func pick(_ titles: [String], typing query: String) async -> String? {
        let store = Fixtures.store()
        for (index, title) in titles.enumerated() {
            store.handle(.updateNewChat(.init(chat: Fixtures.chat(Int64(index + 1), title, positions: [Fixtures.position(Int64(1000 - index))]))))
        }
        await Fixtures.settle()
        let picked = Picked()
        let view = QuickSwitcher(chats: store, files: FileStore(), onPick: { picked.title = $0.displayTitle }, onDismiss: {})
        TestWindow.enableAccessibility()
        let window = TestWindow.host(view, width: 440, height: 480)
        defer { TestWindow.close(window) }
        await TestWindow.settle()
        for character in query { TestWindow.press(String(character), in: window) }
        await TestWindow.settle()
        TestWindow.press("\r", keyCode: kVK_Return, in: window)
        await TestWindow.settle(0.1)
        return picked.title
    }

    @Test func enterOpensTheBestMatch() async {
        #expect(await pick(["Bob Emile", "Émile Zola"], typing: "emile") == "Émile Zola")
        #expect(await pick(["Cosmic Club", "John Smith"], typing: "smi") == "John Smith")
        #expect(await pick(["Bob", "Иван Петров"], typing: "ivan") == "Иван Петров")
    }
}

/// The ⌘K sheet's size, its two chats with one name, and what VoiceOver hears.
@MainActor
@Suite(.serialized)
struct QuickSwitcherLayoutTests {
    private func store(_ titles: [String]) async -> ChatStore {
        let store = Fixtures.store()
        for (index, title) in titles.enumerated() {
            let id = Int64(index + 1)
            store.handle(.updateUser(.init(user: Fixtures.user(id, title))))
            let last = Fixtures.message(id, Fixtures.text("message \(id)"), chat: id)
            store.handle(.updateNewChat(.init(chat: Fixtures.chat(id, title, positions: [Fixtures.position(1000 - Int64(index))], last: last))))
        }
        await Fixtures.settle()
        return store
    }

    /// The sheet is centred in the window, so a sheet that shrinks as results go moves the
    /// field you're typing in.
    @Test func sheetKeepsItsHeightAsResultsChange() async throws {
        let store = await store((1...12).map { "Chat \($0)" })
        TestWindow.enableAccessibility()
        let window = TestWindow.host(QuickSwitcher(chats: store, files: FileStore(), onPick: { _ in }, onDismiss: {}), width: 440, height: 700)
        defer { TestWindow.close(window) }
        let content = try #require(window.contentView)
        await TestWindow.settle()
        let full = content.fittingSize.height
        for character in "chat 7" { TestWindow.press(String(character), in: window) }
        await TestWindow.settle()
        let one = content.fittingSize.height
        for character in "zzz" { TestWindow.press(String(character), in: window) }
        await TestWindow.settle()
        let none = content.fittingSize.height
        #expect(full == one && one == none, "heights \(full), \(one), \(none)")
    }

    @Test func sameNamesAreToldApartAndTheChosenRowIsSelected() async throws {
        let store = await store(["Anna", "Anna", "Max"])
        TestWindow.enableAccessibility()
        let window = TestWindow.host(QuickSwitcher(chats: store, files: FileStore(), onPick: { _ in }, onDismiss: {}), width: 440, height: 700)
        defer { TestWindow.close(window) }
        let content = try #require(window.contentView)
        await TestWindow.settle()
        TestWindow.press("", keyCode: kVK_DownArrow, in: window)
        await TestWindow.settle()
        let elements = TestWindow.accessibilityElements(in: content)
        let tree = elements.map(\.line).joined(separator: "\n")
        #expect(tree.contains("message 1") && tree.contains("message 2"), "\(tree)")
        #expect(!tree.contains("message 3"), "a name that's unique needs no detail")
        let selected = elements.filter(\.isSelected)
        #expect(selected.count == 1 && selected.first?.role == "Button", "\(tree)")
    }
}
