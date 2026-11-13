import HushAI
import HushCore
import SwiftUI

/// The signed-in window: the calm chat list on the left, the selected chat on the right.
struct MainView: View {
    let model: AppModel
    @Bindable var window: WindowState
    /// False while this window is minimized or behind another app's.
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        NavigationSplitView {
            ChatListView(model: model, window: window)
                .navigationSplitViewColumnWidth(min: 250, ideal: 310, max: 420)
        } detail: {
            Group {
                if let conversation = model.conversation, let chat = model.chats.item(conversation.chatId) {
                    ConversationPane(model: model, window: window, conversation: conversation, chat: chat)
                        // A fresh view per chat: its own scroll position and composer focus.
                        .id(conversation.chatId)
                } else {
                    ContentUnavailableView("No Chat Selected", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .toolbar {
                if window.showsChatDetails, model.conversation != nil {
                    ToolbarItem(placement: .navigation) {
                        Button("Back to Chat", systemImage: "chevron.left") { window.showsChatDetails = false }
                            .help("Back to the conversation (Esc)")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Chat Info", systemImage: window.showsChatDetails ? "info.circle.fill" : "info.circle") {
                        window.showsChatDetails.toggle()
                    }
                    .help("Photos, files, links and voice messages in this chat (⌘I)")
                    .disabled(model.conversation == nil)
                }
            }
        }
        .environment(\.vault, model.vault)
        .background {
            WindowVisibilityReader { isOnScreen in
                window.isOnScreen = isOnScreen
                model.isWindowOnScreen = isOnScreen
            } onClose: {
                windowDidClose()
            }
        }
        // A second sign of the same, in case the window goes without AppKit's close notice.
        .onDisappear { windowDidClose() }
        .onChange(of: window.showsArchive) { wasArchive, showsArchive in
            // Switching lists closes a chat from the other list: open, it would have no row.
            guard let chatId = window.selectedChatId, let chat = model.chats.item(chatId) else { return }
            if chat.isIn(wasArchive ? .archive : .main), !chat.isIn(showsArchive ? .archive : .main) {
                window.selectedChatId = nil
            }
        }
        .onChange(of: window.selectedChatId, initial: true) { _, chatId in
            window.showsChatDetails = false
            window.isSearchingChat = false
            model.openConversation(chatId)
        }
        // Photos and videos open over the whole window.
        .overlay {
            if let conversation = model.conversation, let message = conversation.viewerMessage {
                MediaViewer(conversation: conversation, message: message, files: model.files)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.conversation?.viewerMessageId)
        .sheet(isPresented: $window.isChoosingChats, onDismiss: model.chats.finishChoosing) {
            ChooseChatsView(chats: model.chats, files: model.files)
        }
        .sheet(isPresented: $window.isSwitchingChats) {
            QuickSwitcher(
                chats: model.chats,
                files: model.files,
                onPick: { chat in
                    window.isSwitchingChats = false
                    window.searchText = ""
                    window.showsArchive = !chat.isIn(.main)
                    window.selectedChatId = chat.id
                },
                onDismiss: { window.isSwitchingChats = false }
            )
        }
        .confirmationDialog("Log out of Telegram on this Mac?", isPresented: $window.isConfirmingLogOut) {
            Button("Log Out", role: .destructive) { model.auth.logOut() }
        } message: {
            Text("Your chats stay on your other devices.")
        }
        .onChange(of: model.chats.shouldOfferChoosing, initial: true) { _, shouldOffer in
            if shouldOffer { window.isChoosingChats = true }
        }
        // The open chat notifies like any other unless you can see it.
        .onChange(of: appearsActive, initial: true) { _, isActive in model.isMainWindowActive = isActive }
        .onDisappear { model.isMainWindowActive = false }
    }
}

extension MainView {
    private func windowDidClose() {
        window.windowDidClose()
        model.isWindowOnScreen = false
        // A recording would keep going with nothing on screen to show or stop it.
        model.conversation?.cancelRecording()
    }
}

/// The open chat, with its info and shared media in its place while you look at them.
struct ConversationPane: View {
    let model: AppModel
    @Bindable var window: WindowState
    let conversation: ConversationModel
    let chat: ChatItem

    var body: some View {
        ConversationView(
            conversation: conversation,
            chat: chat,
            files: model.files,
            stickers: model.stickers,
            chats: model.chats,
            isSearching: $window.isSearchingChat
        ) {
            window.selectedChatId = nil
        }
        // Under chat info it's covered: VoiceOver mustn't land on what you can't see.
        .accessibilityHidden(window.showsChatDetails)
        // Chat info and shared media take the conversation's place, which stays underneath,
        // scrolled where you left it.
        .overlay {
            if window.showsChatDetails {
                ChatDetailsView(conversation: conversation, chat: chat, files: model.files, chats: model.chats) {
                    window.showsChatDetails = false
                }
            }
        }
    }
}
