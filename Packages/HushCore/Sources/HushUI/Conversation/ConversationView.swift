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
                        ComposerView(conversation: conversation, stickers: stickers, files: files)
                    } else {
                        ChannelFooter()
                    }
                }
            }
            .background(MessagesStyle.background)
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
        .navigationSubtitle(conversation.typingText ?? subtitle(at: now))
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
    private func subtitle(at now: Date) -> String {
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
