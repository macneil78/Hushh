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

/// Shown when the build has no Telegram API credentials.
struct NeedsCredentialsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add your Telegram API credentials")
                .font(.title2.weight(.semibold))
            Text("1. Get an API ID and hash at my.telegram.org → API development tools.")
            Text("2. Copy Config/Secrets.example.xcconfig to Config/Secrets.xcconfig and fill them in.")
            Text("3. Build and run again.")
        }
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
