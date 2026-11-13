import AppKit
import Foundation
import SwiftUI
import Testing
@preconcurrency import TDLibKit
@testable import HushAI
@testable import HushCore
@testable import HushUI

/// The main window's state, menus and Settings, driven in invisible windows.
@MainActor
@Suite(.serialized)
struct MainWindowTests {
    /// A logged-in AppModel without a TDLib session, holding two chats called Anna, Bob in the
    /// archive, and Ágata.
    private func readyModel() async -> AppModel {
        TestWindow.prepare()
        let model = AppModel(configuration: nil)
        model.auth.apply(.authorizationStateReady)
        for chat in [
            Fixtures.chat(301, "Anna", positions: [Fixtures.position(900)]),
            Fixtures.chat(302, "Anna", positions: [Fixtures.position(800)]),
            Fixtures.chat(303, "Bob", positions: [Fixtures.position(700, list: .chatListArchive)]),
            Fixtures.chat(304, "Ágata", positions: [Fixtures.position(600)]),
        ] {
            model.chats.handle(.updateNewChat(.init(chat: chat)))
        }
        await TestWindow.settle()  // the store rebuilds its lists 100 ms after updates
        return model
    }

    /// `view` in an invisible window, once SwiftUI has shown it.
    private func show(_ view: some View, width: CGFloat = 760, height: CGFloat = 520) async -> NSWindow {
        let window = TestWindow.host(view, width: width, height: height)
        await TestWindow.settle(0.4)
        return window
    }

    private func mainView(_ model: AppModel, _ state: WindowState) -> some View {
        MainView(model: model, window: state).frame(minWidth: 760, minHeight: 520)
    }

    /// A switcher or Log Out question left set when the window closes must not pop up, unasked,
    /// the next time the window opens.
    @Test(arguments: ["switcher", "logout"])
    func closingTheWindowDropsItsSheet(_ which: String) async throws {
        let model = await readyModel()
        let state = WindowState()
        let first = await show(mainView(model, state))
        if which == "switcher" { state.isSwitchingChats = true } else { state.isConfirmingLogOut = true }
        await TestWindow.settle(0.5)
        #expect(first.attachedSheet != nil, "asked for while the window is open, it shows")
        TestWindow.close(first)
        await TestWindow.settle(0.3)
        #expect(!state.isSwitchingChats && !state.isConfirmingLogOut)

        let reopened = await show(mainView(model, state))
        defer { TestWindow.close(reopened) }
        await TestWindow.settle(0.8)
        #expect(reopened.attachedSheet == nil, "nothing pops up when the window comes back")
    }

    /// The window tells the menus and AppModel whether you can see it: not while minimized, not
    /// once closed.
    @Test func windowReportsWhetherItIsOnScreen() async throws {
        let model = await readyModel()
        let state = WindowState()
        let window = await show(mainView(model, state))
        #expect(state.isOnScreen && model.isWindowOnScreen)

        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: window)
        #expect(!state.isOnScreen && !model.isWindowOnScreen)
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: window)
        #expect(state.isOnScreen && model.isWindowOnScreen)

        TestWindow.close(window)
        await TestWindow.settle(0.2)
        #expect(!state.isOnScreen && !model.isWindowOnScreen)
    }

    /// ⇧⌘A with a chat from your list open: the chat closes, so the window never shows a chat
    /// with no row for it. Opening an archived chat together with the switch keeps it.
    @Test func switchingListsClosesAChatFromTheOtherList() async throws {
        let model = await readyModel()
        let state = WindowState()
        let window = await show(mainView(model, state))
        defer { TestWindow.close(window) }
        state.selectedChatId = 301
        await TestWindow.settle(0.2)

        state.showsArchive = true
        await TestWindow.settle(0.2)
        #expect(state.selectedChatId == nil)

        state.showsArchive = false
        state.selectedChatId = 301
        await TestWindow.settle(0.2)
        // What the switcher does when you pick an archived chat.
        state.showsArchive = true
        state.selectedChatId = 303
        await TestWindow.settle(0.2)
        #expect(state.selectedChatId == 303)
    }

    /// Previous and Next Chat move through the rows the search leaves, never onto a hidden chat.
    @Test func previousAndNextChatFollowTheSearch() async throws {
        let model = await readyModel()
        let state = WindowState()
        state.searchText = "ag"
        state.moveSelection(by: 1, in: model.chats)
        #expect(state.selectedChatId == 304)
        state.moveSelection(by: -1, in: model.chats)
        #expect(state.selectedChatId == 304)

        state.searchText = "Anna"
        state.selectedChatId = 301
        state.moveSelection(by: 1, in: model.chats)
        #expect(state.selectedChatId == 302)
    }

    /// The conversation under Chat Info is out of the accessibility tree, so VoiceOver can't land
    /// on the message box and buttons you can't see.
    @Test func chatInfoHidesTheConversationFromVoiceOver() async throws {
        let model = await readyModel()
        let session = TDSession()
        let chat = try #require(model.chats.item(301))
        let conversation = ConversationModel(chat: chat, client: session.client, chats: model.chats, voice: model.voice)
        let state = WindowState()
        let window = await show(
            ConversationPane(model: model, window: state, conversation: conversation, chat: chat)
                .environment(ModelStore()),
            width: 600
        )
        let content = try #require(window.contentView)
        TestWindow.enableAccessibility()
        await TestWindow.settle(0.5)
        // The message box.
        let shown = TestWindow.accessibilityElements(in: content)
        #expect(shown.contains { $0.role == "TextArea" }, "the composer is there while the chat shows: \(shown.map(\.line))")

        state.showsChatDetails = true
        await TestWindow.settle(0.5)
        let underInfo = TestWindow.accessibilityElements(in: content)
        #expect(!underInfo.contains { $0.role == "TextArea" }, "\(underInfo.map(\.line))")

        TestWindow.close(window)
        await TestWindow.settle(0.2)
        _ = try? await session.client.close()
    }

    /// Settings is one height for every tab; the tallest content must fit in it unclipped.
    @Test func settingsContentFitsTheOneHeight() async throws {
        let model = await readyModel()
        for (name, view) in [
            ("About", AnyView(AboutSettings(model: model))),
            ("Account, logged out", AnyView(AccountSettings(model: AppModel(configuration: nil)))),
        ] {
            let hosting = NSHostingView(rootView: view.frame(width: 500).environment(Codex()))
            let height = hosting.fittingSize.height
            #expect(height <= SettingsView.height, "\(name) needs \(height) pt")
        }
    }

    /// Reduce Motion reaches views through `reducesMotion`, and a test or the demo can turn it on.
    @Test(arguments: [true, false])
    func reduceMotionReachesViews(_ isOn: Bool) async throws {
        let seen = Seen()
        let window = await show(
            MotionProbe(seen: seen)
                .followsReduceMotion()
                .environment(\._accessibilityReduceMotion, isOn),
            width: 100, height: 100
        )
        defer { TestWindow.close(window) }
        #expect(seen.value == isOn)
    }

    /// When two copies start, exactly one stays: the first launched, or on a tie the lower
    /// process id. Checked on random launch orders, ties and missing launch dates.
    @Test func exactlyOneCopyStays() {
        var random = SystemRandomNumberGenerator()
        let base = Date()
        for _ in 0 ..< 500 {
            let count = Int.random(in: 1 ... 4, using: &random)
            var pids = Set<pid_t>()
            while pids.count < count { pids.insert(pid_t.random(in: 100 ... 99_999, using: &random)) }
            let copies = pids.map { pid in
                HushAppDelegate.Copy(
                    pid: pid,
                    launched: Bool.random(using: &random) && count > 1 && Int.random(in: 0 ... 5, using: &random) == 0
                        ? nil
                        : base.addingTimeInterval(Double(Int.random(in: 0 ... 2, using: &random)))
                )
            }
            // Each copy decides alone, from the same list, whether it is the one to stay.
            let staying = copies.filter { HushAppDelegate.firstStarted(copies) == $0.pid }
            #expect(staying.count == 1)
            let earliest = copies.compactMap(\.launched).min()
            if let earliest, let stays = staying.first {
                #expect(stays.launched == earliest)
            }
        }
    }
}

@MainActor
private final class Seen {
    var value: Bool?
}

private struct MotionProbe: View {
    let seen: Seen
    @Environment(\.reducesMotion) private var reducesMotion

    var body: some View {
        Color.clear.onAppear { seen.value = reducesMotion }
    }
}
