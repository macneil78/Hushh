import AppKit
import HushCore
import SwiftUI

struct RootView: View {
    let model: AppModel
    let window: WindowState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch model.state {
        case .needsCredentials:
            NeedsCredentialsView()
        case .running:
            Group {
                if model.auth.step == .ready {
                    MainView(model: model, window: window)
                } else {
                    LoginView(model: model)
                }
            }
            .onChange(of: model.auth.step == .ready) { _, isReady in
                if !isReady { window.reset() }
            }
            .onAppear { installShowChat() }
        }
    }

    /// Lets notifications open a chat. The closure keeps working after this window closes:
    /// it reopens the window, then selects the chat.
    private func installShowChat() {
        let model = model
        let window = window
        let openWindow = openWindow
        model.onShowChat = { chatId in
            openWindow(id: HushScenes.mainWindowId)
            window.searchText = ""
            if let chat = model.chats.item(chatId) {
                window.showsArchive = !chat.isIn(.main) && chat.isIn(.archive)
            }
            window.selectedChatId = chatId
        }
    }
}

/// Shown when the build has no Telegram API credentials. Most people who see it got a copy
/// someone else built, so it says what's wrong in plain words first, then how to build it.
struct NeedsCredentialsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                Text("This copy of Hushh can't connect to Telegram yet")
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Every Telegram app needs its own API ID and hash, and this copy was built without them. A build contains the credentials of whoever made it, so build Hushh with your own.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Text("To build Hushh yourself:")
                    .font(.headline)
                Text("1. Log in at my.telegram.org with your phone number, open API development tools and create an app. It gives you an API ID and hash.")
                Text("2. Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` and fill them in.")
                Text("3. Build and run again.")
            }
            .fixedSize(horizontal: false, vertical: true)
            Link("Open my.telegram.org", destination: URL(string: "https://my.telegram.org")!)
        }
        // Paths and names can be copied.
        .textSelection(.enabled)
        .frame(maxWidth: 520, alignment: .leading)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
