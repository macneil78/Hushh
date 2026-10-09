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

    /// Forget everything when the account logs out.
    func reset() {
        selectedChatId = nil
        showsArchive = false
        searchText = ""
        isChoosingChats = false
        isConfirmingLogOut = false
        isSwitchingChats = false
    }
}
