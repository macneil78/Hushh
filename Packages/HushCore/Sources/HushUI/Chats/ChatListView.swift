import HushCore
import SwiftUI

/// The sidebar: one list of visible chats (or the Archive), with local search.
struct ChatListView: View {
    let model: AppModel
    @Bindable var window: WindowState

    private var chats: ChatStore { model.chats }
    private var listKind: ChatListKind { window.showsArchive ? .archive : .main }

    private var items: [ChatItem] {
        let list = chats.list(listKind)
        let query = window.searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return list }
        return list.filter { $0.displayTitle.localizedStandardContains(query) }
    }

    var body: some View {
        let items = items
        List(selection: $window.selectedChatId) {
            ForEach(items) { item in
                ChatRow(item: item, files: model.files, list: listKind, isSelected: window.selectedChatId == item.id)
                    .tag(item.id)
                    .contextMenu { ChatContextMenu(item: item, chats: chats, window: window) }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $window.searchText, placement: .sidebar, prompt: "Search")
        .overlay {
            if items.isEmpty { emptyState }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if window.showsArchive { archiveHeader }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    @ViewBuilder private var emptyState: some View {
        if !chats.isLoaded {
            ProgressView()
        } else if !window.searchText.isEmpty {
            ContentUnavailableView.search(text: window.searchText)
        } else if window.showsArchive {
            ContentUnavailableView("No Archived Chats", systemImage: "archivebox")
        } else {
            ContentUnavailableView("No Chats", systemImage: "bubble.left.and.bubble.right")
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

    private var footer: some View {
        HStack {
            Button {
                window.isChoosingChats = true
            } label: {
                Label("Choose Groups & Bots…", systemImage: "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
