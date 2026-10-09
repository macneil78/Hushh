import HushCore
import QuickLook
import SwiftUI

/// The open chat: its messages above, the composer below.
struct ConversationView: View {
    @Bindable var conversation: ConversationModel
    let chat: ChatItem
    let files: FileStore
    let stickers: StickerLibrary

    var body: some View {
        VStack(spacing: 0) {
            MessageTimeline(conversation: conversation, files: files)
            if let error = conversation.errorMessage {
                ErrorBanner(message: error) { conversation.errorMessage = nil }
            }
            ComposerView(conversation: conversation, stickers: stickers, files: files)
        }
        // Drop files anywhere on the conversation to attach them.
        .dropDestination(for: URL.self) { urls, _ in
            conversation.attach(urls)
            return urls.contains(where: \.isFileURL)
        }
        .quickLookPreview($conversation.quickLookURL)
        .navigationTitle(chat.displayTitle)
        .navigationSubtitle(conversation.typingText ?? "")
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
        .background(.orange.opacity(0.12))
    }
}
