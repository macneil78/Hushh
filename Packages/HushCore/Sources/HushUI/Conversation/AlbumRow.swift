import AppKit
import HushCore
import SwiftUI

/// Photos, videos or files sent together: tiled photos and videos, or files in one bubble.
struct AlbumRow: View {
    let messages: [MessageModel]
    let isFirstInGroup: Bool
    let isLastInGroup: Bool
    let isGroup: Bool
    let isRead: Bool
    /// Whether this is your latest message with nothing after it, which shows "Delivered" or "Read".
    let isLatest: Bool
    var isHighlighted = false
    let conversation: ConversationModel
    let files: FileStore
    var swipe: SwipeToReply?
    @State private var isPickingReaction = false

    private var lead: MessageModel { messages[0] }

    var body: some View {
        // Telegram keeps an album's reactions on its first item.
        MessageChrome(
            lead: lead,
            isFirstInGroup: isFirstInGroup,
            isLastInGroup: isLastInGroup,
            isGroup: isGroup,
            isEdited: messages.contains(where: \.isEdited),
            delivery: DeliveryStatus.State(for: messages, isRead: isRead, isLatest: isLatest),
            reactions: lead.reactions,
            canReact: !conversation.reactionChoices.isEmpty,
            files: files,
            swipe: swipe,
            isHighlighted: isHighlighted,
            onTapback: { isPickingReaction = true }
        ) {
            AlbumBubble(messages: messages, hasTail: isLastInGroup, files: files, conversation: conversation)
                .help(lead.date.formatted(date: .abbreviated, time: .shortened))
                .contextMenu { menu }
                .popover(isPresented: $isPickingReaction) {
                    ReactionPicker(
                        choices: conversation.reactionChoices,
                        chosen: Set(lead.reactions.filter(\.isChosen).compactMap {
                            if case .emoji(let emoji) = $0.kind { return emoji }
                            return nil
                        }),
                        onPick: { emoji in
                            isPickingReaction = false
                            conversation.toggleReaction(emoji, on: lead)
                        }
                    )
                }
        }
    }

    @ViewBuilder private var menu: some View {
        if !conversation.reactionChoices.isEmpty {
            Button("Tapback…") { isPickingReaction = true }
        }
        Button("Reply") { conversation.reply(to: lead) }
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
    var hasTail = true
    let files: FileStore
    let conversation: ConversationModel

    private static let gridWidth = MediaSize.box.width
    private static let spacing: CGFloat = 2

    private var lead: MessageModel { messages[0] }
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
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
            if lead.forwardedFrom != nil || lead.reply != nil {
                bubble(hasTail: false) {
                    if let forwardedFrom = lead.forwardedFrom {
                        Text("Forwarded from \(forwardedFrom)")
                            .font(.caption.italic())
                            .opacity(0.75)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let reply = lead.reply {
                        ReplyQuote(reply: reply, isOutgoing: isOutgoing)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if isFileAlbum {
                bubble(hasTail: hasTail && caption == nil) { fileList }
            } else {
                grid
                    .padding(isOutgoing ? .trailing : .leading, MessagesStyle.tailWidth)
            }
            if let caption {
                bubble(hasTail: hasTail) {
                    RichTextView(text: caption, onAccent: isOutgoing)
                        .frame(maxWidth: isFileAlbum ? nil : Self.gridWidth, alignment: .leading)
                }
            }
        }
    }

    private func bubble(hasTail: Bool, @ViewBuilder content: () -> some View) -> some View {
        BubbleLayout(spacing: 4) { content() }
            .bubblePadding(isOutgoing: isOutgoing)
            .foregroundStyle(isOutgoing ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(MessagesStyle.bubbleColor(isOutgoing: isOutgoing), in: BubbleShape(isOutgoing: isOutgoing, hasTail: hasTail))
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
        .clipShape(RoundedRectangle(cornerRadius: MessagesStyle.cornerRadius, style: .continuous))
    }

    @ViewBuilder private func cell(for message: MessageModel, size: CGSize) -> some View {
        switch message.body {
        case .photo(let photo, _):
            PhotoView(photo: photo, files: files, onOpen: { conversation.openViewer(message) }, size: size, cornerRadius: 0)
        case .video(let video, _):
            VideoView(video: video, files: files, onOpen: { conversation.openViewer(message) }, size: size, cornerRadius: 0)
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
        .padding(.vertical, 3)
    }

    /// Right-clicking one item acts on that item alone.
    @ViewBuilder private func itemMenu(for message: MessageModel) -> some View {
        if message.isViewableMedia {
            Button("View") { conversation.openViewer(message) }
        }
        if let fileId = message.fileId, let url = files.handle(for: fileId).localURL {
            if !message.isViewableMedia {
                Button("Quick Look") { open(url) }
            }
            Button("Save As…") { FileActions.saveAs(url, suggestedName: url.lastPathComponent) }
        }
        Divider()
        Button("Reply") { conversation.reply(to: message) }
        Button("Delete…", role: .destructive) { conversation.requestDeletion(of: [message]) }
    }

    private func open(_ url: URL) {
        conversation.quickLookURL = url
    }
}
