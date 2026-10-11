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
}
