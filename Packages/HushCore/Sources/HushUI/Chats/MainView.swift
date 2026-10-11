import HushAI
import HushCore
import SwiftUI

/// The signed-in window: the calm chat list on the left, the selected chat on the right.
struct MainView: View {
    let model: AppModel
    @Bindable var window: WindowState

    var body: some View {
        NavigationSplitView {
            ChatListView(model: model, window: window)
                .navigationSplitViewColumnWidth(min: 250, ideal: 310, max: 420)
        } detail: {
            Group {
                if let conversation = model.conversation, let chat = model.chats.item(conversation.chatId) {
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
                        // A fresh view per chat: its own scroll position and composer focus.
                        .id(conversation.chatId)
                        // Chat info and shared media take the conversation's place, which stays
                        // underneath, scrolled where you left it.
                        .overlay {
                            if window.showsChatDetails {
                                ChatDetailsView(conversation: conversation, chat: chat, files: model.files, chats: model.chats) {
                                    window.showsChatDetails = false
                                }
                                .id(conversation.chatId)
                            }
                        }
                } else {
                    ContentUnavailableView("No Chat Selected", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .toolbar {
                if window.showsChatDetails {
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
    }
}
