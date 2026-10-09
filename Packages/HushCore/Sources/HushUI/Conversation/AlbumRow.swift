import AppKit
import HushCore
import SwiftUI

/// Photos, videos or files sent together, in one bubble.
struct AlbumRow: View {
    let messages: [MessageModel]
    let isFirstInGroup: Bool
    let isLastInGroup: Bool
    let isGroup: Bool
    let isRead: Bool
    let conversation: ConversationModel
    let files: FileStore

    private var lead: MessageModel { messages[0] }
    private var showsSender: Bool { isGroup && !lead.isOutgoing }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if lead.isOutgoing { Spacer(minLength: 80) }
            if showsSender {
                SenderAvatarSlot(sender: lead.sender, showsAvatar: isLastInGroup, files: files)
            }
            VStack(alignment: lead.isOutgoing ? .trailing : .leading, spacing: 4) {
                AlbumBubble(
                    messages: messages,
                    showsSenderName: showsSender && isFirstInGroup,
                    isRead: isRead,
                    files: files,
                    conversation: conversation
                )
                .contextMenu { menu }
                // Telegram keeps an album's reactions on its first item.
                if !lead.reactions.isEmpty {
                    ReactionChips(reactions: lead.reactions) { conversation.toggleReaction($0, on: lead) }
                }
            }
            .frame(maxWidth: 560, alignment: lead.isOutgoing ? .trailing : .leading)
            if !lead.isOutgoing { Spacer(minLength: 80) }
        }
        .padding(.top, isFirstInGroup ? 8 : 2)
    }

    @ViewBuilder private var menu: some View {
        Button("Reply") { conversation.reply(to: lead) }
        let choices = conversation.reactionChoices
        if !choices.isEmpty {
            Menu("React") {
                ForEach(choices.prefix(16), id: \.self) { emoji in
                    Button(emoji) { conversation.toggleReaction(emoji, on: lead) }
                }
            }
        }
        if let caption = messages.lazy.compactMap(\.caption).first(where: { !$0.isEmpty }) {
            Button("Copy Caption") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(caption.text, forType: .string)
            }
        }
        Divider()
        Button("Delete All \(messages.count) Items…", role: .destructive) {
            conversation.requestDeletion(of: messages)
        }
    }
}

struct AlbumBubble: View {
    let messages: [MessageModel]
    let showsSenderName: Bool
    let isRead: Bool
    let files: FileStore
    let conversation: ConversationModel

    private static let gridWidth = MediaSize.box.width
    private static let spacing: CGFloat = 2

    private var lead: MessageModel { messages[0] }
    private var last: MessageModel { messages[messages.count - 1] }
    private var isOutgoing: Bool { lead.isOutgoing }

    /// Albums of files list them; albums of photos and videos tile them.
    private var isFileAlbum: Bool {
        messages.allSatisfy {
            if case .document = $0.body { return true }
            return false
        }
    }

    /// Telegram puts an album's caption on one of its items, usually the first.
    private var caption: RichText? {
        messages.lazy.compactMap(\.caption).first { !$0.isEmpty }
    }

    var body: some View {
        BubbleLayout(spacing: 4) {
            if showsSenderName {
                Text(lead.sender.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AccentPalette.color(for: lead.sender.accentColorId))
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let forwardedFrom = lead.forwardedFrom {
                Text("Forwarded from \(forwardedFrom)")
                    .font(.caption.italic())
                    .opacity(0.75)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let reply = lead.reply {
                ReplyQuote(reply: reply, isOutgoing: isOutgoing)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if isFileAlbum {
                fileList
            } else {
                grid
            }
            if let caption {
                RichTextView(text: caption, onAccent: isOutgoing)
                    .padding(.horizontal, 6)
                    .frame(width: isFileAlbum ? nil : Self.gridWidth, alignment: .leading)
            }
            footer
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(4)
        .foregroundStyle(isOutgoing ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(
            isOutgoing ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.7)),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    /// Two per row; an odd last item spans the full width.
    private var grid: some View {
        let rows = stride(from: 0, to: messages.count, by: 2).map { Array(messages[$0 ..< min($0 + 2, messages.count)]) }
        return VStack(spacing: Self.spacing) {
            ForEach(rows, id: \.first!.id) { row in
                HStack(spacing: Self.spacing) {
                    ForEach(row) { message in
                        cell(for: message, size: CGSize(
                            width: row.count == 1 ? Self.gridWidth : (Self.gridWidth - Self.spacing) / 2,
                            height: row.count == 1 ? 220 : 170
                        ))
                        .contextMenu { itemMenu(for: message) }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private func cell(for message: MessageModel, size: CGSize) -> some View {
        switch message.body {
        case .photo(let photo, _):
            PhotoView(photo: photo, files: files, onOpen: open, size: size, cornerRadius: 0)
        case .video(let video, _):
            VideoView(video: video, files: files, onOpen: open, size: size, cornerRadius: 0)
        default:
            Rectangle()
                .fill(.quaternary)
                .frame(width: size.width, height: size.height)
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(messages) { message in
                if case .document(let document, _) = message.body {
                    DocumentView(document: document, files: files, onOpen: open)
                        .contextMenu { itemMenu(for: message) }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// Right-clicking one item acts on that item alone.
    @ViewBuilder private func itemMenu(for message: MessageModel) -> some View {
        if let fileId = message.fileId, let url = files.handle(for: fileId).localURL {
            Button("Quick Look") { open(url) }
            Button("Save As…") { FileActions.saveAs(url, suggestedName: url.lastPathComponent) }
            Divider()
        }
        Button("Reply") { conversation.reply(to: message) }
        Button("Delete…", role: .destructive) { conversation.requestDeletion(of: [message]) }
    }

    private func open(_ url: URL) {
        conversation.quickLookURL = url
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if messages.contains(where: \.isEdited) {
                Text("edited")
            }
            Text(last.date.formatted(date: .omitted, time: .shortened))
            if isOutgoing { statusIcon }
        }
        .font(.caption2)
        .opacity(0.7)
    }

    @ViewBuilder private var statusIcon: some View {
        if let failed = messages.first(where: { if case .failed = $0.status { true } else { false } }),
           case .failed(let reason) = failed.status {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .help("Not sent: \(reason)")
        } else if messages.contains(where: { $0.status == .sending }) {
            Image(systemName: "clock")
        } else {
            HStack(spacing: -6) {
                Image(systemName: "checkmark")
                if isRead { Image(systemName: "checkmark") }
            }
            .help(isRead ? "Read" : "Sent")
        }
    }
}
