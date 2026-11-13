import AppKit
import HushCore
import SwiftUI

/// Where to forward messages: the chats Hushh shows (only ones you can write in), Saved Messages
/// first, as in Telegram.
struct ForwardPicker: View {
    let conversation: ConversationModel
    let chats: ChatStore
    let files: FileStore
    @State private var query = ""
    @State private var isSending = false

    private var candidates: [ChatItem] {
        let saved = chats.savedMessages.map { [$0] } ?? []
        let others = chats.mainList.filter { $0.kind != .savedMessages && chats.canPost(in: $0) }
        let all = saved + others
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? all : all.filter { $0.displayTitle.localizedStandardContains(query) }
    }

    var body: some View {
        let count = conversation.forwarding?.count ?? 0
        VStack(spacing: 0) {
            HStack {
                Text(count == 1 ? "Forward Message" : "Forward \(count) Messages")
                    .font(.headline)
                Spacer()
                Button("Cancel") { conversation.forwarding = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 10)
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            List(candidates) { item in
                Button { forward(to: item) } label: {
                    HStack(spacing: 10) {
                        AvatarView(item: item, files: files, size: 32)
                        Text(item.displayTitle)
                            .lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
        .frame(width: 380, height: 460)
        .disabled(isSending)
        .overlay { if isSending { ProgressView() } }
    }

    private func forward(to item: ChatItem) {
        guard let messages = conversation.forwarding else { return }
        isSending = true
        Task {
            if await conversation.forward(messages, to: item.id, named: item.displayTitle) {
                conversation.endSelecting()
            }
            isSending = false
            conversation.forwarding = nil
        }
    }
}

/// While picking messages with Select: how many, and what to do with them. Takes the message
/// field's place; Esc stops selecting.
struct SelectionBar: View {
    let conversation: ConversationModel

    var body: some View {
        let selected = conversation.selectedMessages
        HStack(spacing: 14) {
            Button("Cancel") { conversation.endSelecting() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Text(selected.isEmpty ? "Select messages" : selected.count == 1 ? "1 message" : "\(selected.count) messages")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ConversationModel.copiedText(of: selected), forType: .string)
                conversation.endSelecting()
            }
            .disabled(selected.isEmpty)
            Button("Forward", systemImage: "arrowshape.turn.up.right") { conversation.forwarding = selected }
                .disabled(selected.isEmpty)
            Button("Delete", systemImage: "trash", role: .destructive) { conversation.requestDeletion(of: selected) }
                .disabled(selected.isEmpty)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .frame(height: 40)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }
}

/// The chat's pinned message, at the top as in Telegram. Click it to jump there.
struct PinnedBar: View {
    let message: MessageModel
    let onOpen: () -> Void
    let onUnpin: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(MessagesStyle.outgoing)
                .frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Pinned Message")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MessagesStyle.outgoing)
                Text(message.previewText)
                    .font(.callout)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Unpin", systemImage: "pin.slash", action: onUnpin)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Unpin")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }
}

/// A short confirmation over the bottom of the chat, like "Forwarded to Emma".
struct NoticeCapsule: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: Capsule())
            .padding(.bottom, 4)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
