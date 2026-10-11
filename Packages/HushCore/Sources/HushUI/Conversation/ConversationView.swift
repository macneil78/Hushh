import HushAI
import HushCore
import QuickLook
import SwiftUI

/// The open chat: its messages above, the composer below.
struct ConversationView: View {
    @Bindable var conversation: ConversationModel
    let chat: ChatItem
    let files: FileStore
    let stickers: StickerLibrary
    let chats: ChatStore
    /// ⌘F's search panel.
    @Binding var isSearching: Bool
    /// Esc in the message box with nothing to cancel closes the chat.
    var onClose: () -> Void = {}
    @Environment(ModelStore.self) private var models
    @Environment(\.vault) private var vault
    @State private var search: ChatSearch?
    @State private var drop: DropState?
    @State private var now = Date.now
    @State private var height: CGFloat = 0

    var body: some View {
        // The composer floats over the bottom of the conversation, which scrolls under it.
        MessageTimeline(conversation: conversation, files: files)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if let error = conversation.errorMessage {
                        ErrorBanner(message: error) { conversation.errorMessage = nil }
                    }
                    if conversation.canPost {
                        ComposerView(conversation: conversation, stickers: stickers, files: files, onClose: onClose)
                    } else {
                        ChannelFooter()
                    }
                }
            }
            .overlay(alignment: .top) {
                if isSearching, let search {
                    ChatSearchView(search: search, conversation: conversation) { isSearching = false }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.15), value: isSearching)
            .onChange(of: isSearching, initial: true) { _, isOpen in
                if isOpen {
                    if search == nil {
                        search = ChatSearch(conversation: conversation, models: models, vault: vault)
                    }
                    search?.start()
                } else {
                    search?.stop()
                    conversation.requestFocus()
                }
            }
            .onDisappear { search?.stop() }
            .background(MessagesStyle.background)
            .environment(\.conversation, conversation)
        // Drop files anywhere on the conversation: top half as files, bottom half as photos and videos.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .onDrop(of: [.fileURL], delegate: AttachmentDropDelegate(
            state: $drop,
            height: height,
            isEnabled: conversation.canPost,
            onDrop: { urls, asFiles in conversation.attach(urls, asFiles: asFiles) }
        ))
        .overlay {
            if let drop { DropZonesOverlay(state: drop) }
        }
        .quickLookPreview($conversation.quickLookURL)
        .navigationTitle(chat.displayTitle)
        .navigationSubtitle(conversation.typingText ?? Self.subtitle(for: chat, chats: chats, at: now))
        // "last seen 5 minutes ago" ages, so refresh it now and then.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = .now
            }
        }
        .confirmationDialog(
            (conversation.pendingDeletion?.messages.count ?? 1) > 1
                ? "Delete these \(conversation.pendingDeletion?.messages.count ?? 0) items?"
                : "Delete this message?",
            isPresented: Binding(
                get: { conversation.pendingDeletion != nil },
                set: { if !$0 { conversation.pendingDeletion = nil } }
            ),
            presenting: conversation.pendingDeletion
        ) { deletion in
            if deletion.canDeleteForEveryone {
                Button("Delete for Everyone", role: .destructive) { conversation.delete(deletion, forEveryone: true) }
            }
            if deletion.canDeleteForMe {
                Button("Delete for Me", role: .destructive) { conversation.delete(deletion, forEveryone: false) }
            }
        }
        .confirmationDialog(
            conversation.sponsoredReport?.title ?? "Report Ad",
            isPresented: Binding(
                get: { conversation.sponsoredReport != nil },
                set: { if !$0 { conversation.sponsoredReport = nil } }
            ),
            presenting: conversation.sponsoredReport
        ) { report in
            ForEach(report.options) { option in
                Button(option.text) { conversation.reportSponsoredAd(option: option) }
            }
        }
    }
}

extension ConversationView {
    /// Under the chat's name: online or last seen for people, size for groups and channels.
    static func subtitle(for chat: ChatItem, chats: ChatStore, at now: Date = .now) -> String {
        switch chat.kind {
        case .person, .secret:
            return chat.presence?.text(now: now) ?? ""
        case .bot:
            return "bot"
        case .group:
            return chats.memberCount(of: chat).map { "\($0) member\($0 == 1 ? "" : "s")" } ?? ""
        case .channel:
            return chats.memberCount(of: chat).map { "\($0) subscriber\($0 == 1 ? "" : "s")" } ?? ""
        case .service:
            return "service notifications"
        case .savedMessages:
            return ""
        }
    }
}

struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
            Spacer()
            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular.tint(.orange.opacity(0.25)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }
}
