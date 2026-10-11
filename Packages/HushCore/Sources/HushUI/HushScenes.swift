import AppKit
import HushAI
import HushCore
import SwiftUI

/// The app's scenes. The Xcode app target only hosts these, so everything here builds and
/// type-checks with `swift build`.
public struct HushScenes: Scene {
    static let mainWindowId = "main"

    private let model: AppModel
    @State private var window = WindowState()
    /// On-device AI models, shared by every account.
    @State private var models = ModelStore()

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some Scene {
        // One window, like Signal. Closing it keeps Hush running so messages keep arriving.
        Window("Hushh", id: Self.mainWindowId) {
            if DemoWindow.isEnabled {
                // Made-up chats for screenshots; Telegram is never touched.
                DemoWindow()
                    .frame(width: 1080, height: 700)
            } else {
                RootView(model: model, window: window)
                    .environment(models)
                    .frame(minWidth: 760, minHeight: 520)
                    .task { model.start() }
            }
        }
        .commands {
            HushCommands(model: model, window: window)
        }

        Settings {
            SettingsView(model: model)
                .environment(models)
        }
    }
}

struct HushCommands: Commands {
    let model: AppModel
    let window: WindowState

    private var isReady: Bool { model.auth.step == .ready }

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Log Out…") { window.isConfirmingLogOut = true }
                .disabled(!isReady)
        }
        CommandMenu("Chat") {
            Button("Find in Chat…") { window.isSearchingChat = true }
                .keyboardShortcut("f")
                .disabled(model.conversation == nil)
            let recorder = model.conversation?.recorder
            Button(recorder?.state == .recording ? "Send Voice Message" : "Record Voice Message") {
                model.conversation?.toggleRecording()
            }
            .keyboardShortcut("r")
            .disabled(model.conversation?.canPost != true || recorder?.state == .encoding)
        }
        CommandMenu("Go") {
            Button("Switch to Chat…") { window.isSwitchingChats = true }
                .keyboardShortcut("k")
                .disabled(!isReady)
            Divider()
            Button("Previous Chat") { moveSelection(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                .disabled(!isReady)
            Button("Next Chat") { moveSelection(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.option, .command])
                .disabled(!isReady)
            Divider()
            // ⌘1–⌘9: the first nine chats in your list.
            ForEach(Array(model.chats.mainList.prefix(9).enumerated()), id: \.element.id) { index, chat in
                Button(chat.displayTitle) {
                    window.showsArchive = false
                    window.selectedChatId = chat.id
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
        CommandGroup(after: .sidebar) {
            Button(window.showsArchive ? "Show Chats" : "Show Archived Chats") {
                window.showsArchive.toggle()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(!isReady)
            Button(window.showsChatDetails ? "Back to Chat" : "Show Chat Info") {
                window.showsChatDetails.toggle()
            }
            .keyboardShortcut("i")
            .disabled(!isReady)
            // Choosing which groups, channels and bots to show lives in Settings only, a step
            // away, so adding one is a deliberate choice.
        }
    }
}

extension HushCommands {
    private func moveSelection(by step: Int) {
        let list = model.chats.list(window.showsArchive ? .archive : .main)
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == window.selectedChatId }
        let next = current.map { min(max($0 + step, 0), list.count - 1) } ?? (step > 0 ? 0 : list.count - 1)
        window.selectedChatId = list[next].id
    }
}

/// Keeps Hush running after its window closes; clicking the Dock icon brings the window back.
public final class HushAppDelegate: NSObject, NSApplicationDelegate {
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
