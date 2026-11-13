import AppKit
import HushAI
import HushCore
import SwiftUI

/// The app's scenes. The Xcode app target only hosts these, so everything here builds and
/// type-checks with `swift build`.
public struct HushScenes: Scene {
    /// The demo's window has an id of its own, so its fixed size isn't saved as the real
    /// window's frame.
    static var mainWindowId: String { DemoWindow.isEnabled ? "demo" : "main" }

    private let model: AppModel
    @State private var window = WindowState()
    /// On-device AI models, shared by every account.
    @State private var models = ModelStore()
    /// Codex, for Catch Up, drafts and translations, if it's set up.
    @State private var codex = Codex()

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some Scene {
        // One window, like Signal. Closing it keeps Hush running so messages keep arriving.
        Window("Hushh", id: Self.mainWindowId) {
            Group {
                if DemoWindow.isEnabled {
                    // Made-up chats for screenshots; Telegram is never touched.
                    DemoWindow()
                        .frame(width: 1080, height: 700)
                } else {
                    RootView(model: model, window: window)
                        .environment(models)
                        .environment(codex)
                        .frame(minWidth: 760, minHeight: 520)
                        .task { model.start() }
                }
            }
            .followsReduceMotion()
        }
        .commands {
            HushCommands(model: model, window: window)
        }

        Settings {
            Group {
                if DemoWindow.isEnabled {
                    // The demo leaves the real app's settings and AI models alone.
                    Text("Settings are off in the demo.")
                        .foregroundStyle(.secondary)
                        .padding(40)
                } else {
                    SettingsView(model: model)
                        .environment(models)
                        .environment(codex)
                }
            }
            .followsReduceMotion()
        }
        // Here, not on the window: commands the window's scene puts after Settings… end up above it.
        .commands {
            AccountCommands(model: model, window: window)
        }
    }
}

/// Hushh → Log Out…, under Settings….
struct AccountCommands: Commands {
    let model: AppModel
    let window: WindowState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Log Out…") {
                window.show(with: openWindow) { window.isConfirmingLogOut = true }
            }
            .disabled(model.auth.step != .ready)
        }
    }
}

struct HushCommands: Commands {
    let model: AppModel
    let window: WindowState
    @Environment(\.openWindow) private var openWindow

    private var isReady: Bool { model.auth.step == .ready }
    /// The open chat, if you can see it: never with the window closed or minimized.
    private var chatOnScreen: ConversationModel? { window.isOnScreen ? model.conversation : nil }

    var body: some Commands {
        CommandMenu("Chat") {
            Button("Find in Chat…") { window.isSearchingChat = true }
                .keyboardShortcut("f")
                .disabled(chatOnScreen == nil)
            let recorder = chatOnScreen?.recorder
            Button(recorder?.state == .recording ? "Send Voice Message" : "Record Voice Message") {
                chatOnScreen?.toggleRecording()
            }
            .keyboardShortcut("r")
            // Only with the chat in front of you, so the microphone never records, or sends, unseen.
            .disabled(chatOnScreen?.canPost != true || recorder?.state == .encoding)
        }
        CommandMenu("Go") {
            Button("Switch to Chat…") {
                window.show(with: openWindow) { window.isSwitchingChats = true }
            }
            .keyboardShortcut("k")
            .disabled(!isReady)
            Divider()
            Button("Previous Chat") {
                window.show(with: openWindow) { window.moveSelection(by: -1, in: model.chats) }
            }
            .keyboardShortcut(.upArrow, modifiers: [.option, .command])
            .disabled(!isReady)
            Button("Next Chat") {
                window.show(with: openWindow) { window.moveSelection(by: 1, in: model.chats) }
            }
            .keyboardShortcut(.downArrow, modifiers: [.option, .command])
            .disabled(!isReady)
            Divider()
            // ⌘1–⌘9: the first nine chats in your list. Two with one name get a detail each.
            let first = Array(model.chats.mainList.prefix(9))
            let details = ChatItem.details(tellingApart: first)
            ForEach(Array(first.enumerated()), id: \.element.id) { index, chat in
                Button(details[chat.id].map { "\(chat.displayTitle) — \($0)" } ?? chat.displayTitle) {
                    window.show(with: openWindow) {
                        // Like picking it in the switcher: clear the search so its row shows.
                        window.searchText = ""
                        window.showsArchive = false
                        window.selectedChatId = chat.id
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
        CommandGroup(after: .sidebar) {
            Button(window.showsArchive ? "Show Chats" : "Show Archived Chats") {
                window.show(with: openWindow) { window.showsArchive.toggle() }
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(!isReady)
            Button(window.showsChatDetails ? "Back to Chat" : "Show Chat Info") {
                window.showsChatDetails.toggle()
            }
            .keyboardShortcut("i")
            .disabled(chatOnScreen == nil)
            // Choosing which groups, channels and bots to show lives in Settings only, a step
            // away, so adding one is a deliberate choice.
        }
    }
}

extension WindowState {
    /// For a command that shows something in the main window: brings the window to the front
    /// first, reopening it if it was closed, so what the command shows appears now, in front of
    /// you, and never later when the window comes back.
    func show(with openWindow: OpenWindowAction, _ change: () -> Void) {
        openWindow(id: HushScenes.mainWindowId)
        change()
    }
}

/// Keeps Hush running after its window closes; clicking the Dock icon brings the window back.
public final class HushAppDelegate: NSObject, NSApplicationDelegate {
    public func applicationWillFinishLaunching(_ notification: Notification) {
        // Two copies would open the same TDLib database, which TDLib locks: the second could
        // only show an error. Hand over to the copy that's already running. Nothing is open yet,
        // so there's nothing to save. The demo never opens the database, so it may run beside.
        guard !DemoWindow.isEnabled, let running = Self.copyAlreadyRunning() else { return }
        running.activate()
        exit(0)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Another Hushh that started before this one, by bundle id, so a Debug and a Release build
    /// count as the same app: they share the database too.
    private static func copyAlreadyRunning() -> NSRunningApplication? {
        guard let bundleId = Bundle.main.bundleIdentifier else { return nil }
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).filter { !$0.isTerminated }
        let first = firstStarted(copies.map { Copy(pid: $0.processIdentifier, launched: $0.launchDate) })
        guard let first, first != ProcessInfo.processInfo.processIdentifier else { return nil }
        return copies.first { $0.processIdentifier == first }
    }

    struct Copy {
        let pid: pid_t
        let launched: Date?
    }

    /// The copy that keeps running: the one launched first. Two copies started at the same moment
    /// agree on the lower process id, so exactly one of them stays.
    static func firstStarted(_ copies: [Copy]) -> pid_t? {
        copies.min { a, b in
            let aDate = a.launched ?? .distantFuture
            let bDate = b.launched ?? .distantFuture
            return aDate != bDate ? aDate < bDate : a.pid < b.pid
        }?.pid
    }
}
