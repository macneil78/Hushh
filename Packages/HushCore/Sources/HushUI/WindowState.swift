import HushCore
import Observation

/// UI state of the main window, shared with the menu commands.
@MainActor @Observable
final class WindowState {
    var selectedChatId: Int64?
    var showsArchive = false
    var searchText = ""
    var isChoosingChats = false
    var isConfirmingLogOut = false
    var isSwitchingChats = false
    /// The chat's info and shared media, shown in place of the conversation.
    var showsChatDetails = false
    /// ⌘F: the search panel over the conversation.
    var isSearchingChat = false
    /// Whether the signed-in window is open and not minimized. Menu commands that show something
    /// in it bring it back first; the ones that act on the chat you see need it.
    var isOnScreen = false

    /// Forget everything when the account logs out.
    func reset() {
        selectedChatId = nil
        showsArchive = false
        searchText = ""
        isChoosingChats = false
        isConfirmingLogOut = false
        isSwitchingChats = false
        showsChatDetails = false
        isSearchingChat = false
    }

    /// The window closed: drop the sheet and dialog it showed, so they don't pop up out of
    /// nowhere when it opens again.
    func windowDidClose() {
        isOnScreen = false
        isConfirmingLogOut = false
        isSwitchingChats = false
    }

    /// The chats the sidebar shows: the current list, narrowed by the search field.
    func listedChats(in chats: ChatStore) -> [ChatItem] {
        let list = chats.list(showsArchive ? .archive : .main)
        guard let match = NameMatch(searchText) else { return list }
        return list.filter { match.matches($0.displayTitle) }
    }

    /// Previous or Next Chat: moves through the rows the sidebar shows, so the selection never
    /// lands on a chat the search hides.
    func moveSelection(by step: Int, in chats: ChatStore) {
        let list = listedChats(in: chats)
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selectedChatId }
        let next = current.map { min(max($0 + step, 0), list.count - 1) } ?? (step > 0 ? 0 : list.count - 1)
        selectedChatId = list[next].id
    }
}
