import AppKit
import HushCore
import SwiftUI

/// The sidebar: one list of visible chats (or the Archive), with local search.
struct ChatListView: View {
    let model: AppModel
    @Bindable var window: WindowState

    /// Hovering a dragged file over a chat for a moment opens it, as in Telegram.
    @State private var springLoad: Task<Void, Never>?

    private var chats: ChatStore { model.chats }
    private var listKind: ChatListKind { window.showsArchive ? .archive : .main }

    private var items: [ChatItem] { window.listedChats(in: chats) }

    var body: some View {
        let items = items
        List(selection: $window.selectedChatId) {
            ForEach(items) { item in
                ChatRow(item: item, files: model.files, list: listKind, isSelected: window.selectedChatId == item.id)
                    .tag(item.id)
                    .contextMenu { ChatContextMenu(item: item, chats: chats, window: window) }
                    .onDrop(of: [.fileURL], delegate: ChatRowDropDelegate(
                        onTargeted: { springLoad(item, isTargeted: $0) },
                        onDrop: { drop($0, on: item) }
                    ))
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $window.searchText, placement: .sidebar, prompt: "Search")
        .task(id: window.searchText) {
            // Once typing pauses, also ask Telegram's servers: a chat the downloaded list left
            // out then joins the list and shows up here.
            guard !window.searchText.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await chats.searchServer(window.searchText)
        }
        .overlay {
            if items.isEmpty { emptyState }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if window.showsArchive { archiveHeader }
        }
        .alert(
            "Couldn't Change the Chat",
            isPresented: Binding(get: { chats.actionError != nil }, set: { if !$0 { chats.actionError = nil } }),
            presenting: chats.actionError
        ) { _ in
            Button("OK") {}
        } message: { error in
            Text(error)
        }
    }

    /// Dropped straight onto a chat: open it with the files attached, ready for a caption.
    private func drop(_ urls: [URL], on item: ChatItem) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        window.selectedChatId = item.id
        model.openConversation(item.id)
        guard let conversation = model.conversation, conversation.canPost else { return false }
        conversation.attach(files)
        return true
    }

    private func springLoad(_ item: ChatItem, isTargeted: Bool) {
        springLoad?.cancel()
        springLoad = nil
        guard isTargeted, window.selectedChatId != item.id else { return }
        springLoad = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            window.selectedChatId = item.id
        }
    }

    @ViewBuilder private var emptyState: some View {
        if let match = NameMatch(window.searchText) {
            noResults(match)
        } else if !chats.isLoaded {
            ProgressView()
        } else if window.showsArchive {
            ContentUnavailableView("No Archived Chats", systemImage: "archivebox")
        } else {
            ContentUnavailableView("No Chats", systemImage: "bubble.left.and.bubble.right")
        }
    }

    /// Nothing in this list matches: say where matching chats are, the other list or hidden.
    private func noResults(_ match: NameMatch) -> some View {
        let otherList = chats.list(window.showsArchive ? .main : .archive).filter { match.matches($0.displayTitle) }
        let hidden = chats.chatsToChoose().filter { !chats.isShown($0) && match.matches($0.displayTitle) }
        return ContentUnavailableView {
            Label("No Results for “\(window.searchText)”", systemImage: "magnifyingglass")
        } description: {
            if !hidden.isEmpty {
                Text(hidden.count == 1
                     ? "“\(hidden[0].displayTitle)” is hidden. To show it, switch it on in Settings → Chats."
                     : "\(hidden.count) hidden chats match. To show them, switch them on in Settings → Chats.")
            } else if otherList.isEmpty {
                // While chats are still arriving, a match may yet come: say so, not "No Results".
                Text(chats.isLoaded ? "Check the spelling or try a new search." : "Searching…")
            }
        } actions: {
            if !otherList.isEmpty {
                Button(window.showsArchive
                       ? "Show \(otherList.count) in Chats"
                       : "Show \(otherList.count) in Archived Chats") {
                    window.showsArchive.toggle()
                }
            }
        }
    }

    private var archiveHeader: some View {
        HStack {
            Button {
                window.showsArchive = false
            } label: {
                Label("Archived Chats", systemImage: "chevron.left")
                    .font(.headline)
            }
            .buttonStyle(.borderless)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// Files dropped onto a chat in the sidebar, read off the drag pasteboard during the drop as the
/// conversation's own drop zones do.
struct ChatRowDropDelegate: DropDelegate {
    let onTargeted: (Bool) -> Void
    let onDrop: ([URL]) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        onTargeted(true)
    }

    func dropExited(info: DropInfo) {
        onTargeted(false)
    }

    func performDrop(info: DropInfo) -> Bool {
        onTargeted(false)
        return onDrop(AttachmentDropDelegate.fileURLs(on: NSPasteboard(name: .drag)))
    }
}

struct ChatContextMenu: View {
    let item: ChatItem
    let chats: ChatStore
    let window: WindowState

    var body: some View {
        if item.hasUnread || item.unreadMentionCount > 0 {
            Button("Mark as Read") { chats.markAsRead(item) }
        } else {
            Button("Mark as Unread") { chats.markAsUnread(item) }
        }
        Divider()
        let list: ChatListKind = window.showsArchive ? .archive : .main
        if item.isPinned(in: list) {
            Button("Unpin") { chats.setPinned(false, item) }
        } else {
            Button("Pin") { chats.setPinned(true, item) }
        }
        if item.kind != .savedMessages {
            if item.isMuted {
                Button("Unmute") { chats.setMuted(item, for: nil) }
            } else {
                Menu("Mute") {
                    Button("For 1 Hour") { chats.setMuted(item, for: 3_600) }
                    Button("For 8 Hours") { chats.setMuted(item, for: 28_800) }
                    Button("For 2 Days") { chats.setMuted(item, for: 172_800) }
                    Button("Forever") { chats.setMuted(item, for: .max) }
                }
            }
        }
        Divider()
        if item.kind != .savedMessages {
            if item.isIn(.archive) {
                Button("Unarchive") { chats.setArchived(false, item) }
            } else {
                Button("Archive") { chats.setArchived(true, item) }
            }
        }
        Button("Hide from List") {
            if window.selectedChatId == item.id { window.selectedChatId = nil }
            chats.setShown(false, for: item)
        }
    }
}
