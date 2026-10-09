import AppKit
import HushCore
import SwiftUI

/// One message: a centered grey line for service messages, otherwise a bubble.
struct MessageRow: View {
    let message: MessageModel
    let isFirstInGroup: Bool
    let isLastInGroup: Bool
    let isGroup: Bool
    let isRead: Bool
    let conversation: ConversationModel
    let files: FileStore
    @State private var isHovering = false
    @State private var isPickingReaction = false

    /// In groups, other people's messages carry their name and picture.
    private var showsSender: Bool { isGroup && !message.isOutgoing }

    var body: some View {
        if case .service(let text) = message.body {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                if message.isOutgoing { Spacer(minLength: 80) }
                if showsSender {
                    SenderAvatarSlot(sender: message.sender, showsAvatar: isLastInGroup, files: files)
                }
                // The react button hugs the bubble, on the side facing the middle of the window.
                HStack(alignment: .center, spacing: 6) {
                    if message.isOutgoing { reactButton }
                    VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                        MessageBubble(
                            message: message,
                            showsSenderName: showsSender && isFirstInGroup,
                            isRead: isRead,
                            files: files,
                            onOpen: { conversation.quickLookURL = $0 },
                            voice: conversation.voice,
                            onPlayVoice: { conversation.playVoiceNote(message, url: $0) }
                        )
                        .contextMenu { menu }
                        if !message.reactions.isEmpty {
                            ReactionChips(reactions: message.reactions) { conversation.toggleReaction($0, on: message) }
                        }
                    }
                    if !message.isOutgoing { reactButton }
                }
                .frame(maxWidth: 600, alignment: message.isOutgoing ? .trailing : .leading)
                if !message.isOutgoing { Spacer(minLength: 80) }
            }
            .padding(.top, isFirstInGroup ? 8 : 2)
            .onHover { isHovering = $0 }
        }
    }

    /// Appears beside the bubble on hover; always takes its space so nothing shifts.
    private var reactButton: some View {
        Button("React", systemImage: "face.smiling") { isPickingReaction = true }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(isHovering || isPickingReaction ? 1 : 0)
            .popover(isPresented: $isPickingReaction) {
                ReactionPicker(
                    choices: conversation.reactionChoices,
                    chosen: Set(message.reactions.filter(\.isChosen).compactMap {
                        if case .emoji(let emoji) = $0.kind { return emoji }
                        return nil
                    }),
                    onPick: { emoji in
                        isPickingReaction = false
                        conversation.toggleReaction(emoji, on: message)
                    }
                )
            }
    }

    @ViewBuilder private var menu: some View {
        Button("Reply") { conversation.reply(to: message) }
        let choices = conversation.reactionChoices
        if !choices.isEmpty {
            Menu("React") {
                ForEach(choices.prefix(16), id: \.self) { emoji in
                    Button(emoji) { conversation.toggleReaction(emoji, on: message) }
                }
            }
        }
        if message.canEditText {
            Button("Edit") { conversation.startEditing(message) }
        }
        if !message.plainText.isEmpty {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.plainText, forType: .string)
            }
        }
        if let fileId = message.fileId, let url = files.handle(for: fileId).localURL {
            Button("Quick Look") { conversation.quickLookURL = url }
            Button("Save As…") { FileActions.saveAs(url, suggestedName: suggestedFileName(for: url)) }
        }
        Divider()
        Button("Delete…", role: .destructive) { conversation.requestDeletion(of: [message]) }
    }

    private func suggestedFileName(for url: URL) -> String {
        if case .document(let document, _) = message.body, (document.fileName as NSString).pathExtension.isEmpty == false {
            return document.fileName
        }
        return url.lastPathComponent
    }
}

struct MessageBubble: View {
    let message: MessageModel
    let showsSenderName: Bool
    let isRead: Bool
    let files: FileStore
    /// Opens a downloaded file in Quick Look.
    let onOpen: (URL) -> Void
    /// Plays voice messages; nil where nothing can play (previews and tests).
    var voice: VoicePlayback?
    var onPlayVoice: (URL) -> Void = { _ in }

    private var isOutgoing: Bool { message.isOutgoing }

    /// Stickers and round videos stand on their own, without a bubble.
    private var isBare: Bool {
        switch message.body {
        case .sticker, .videoNote: true
        default: false
        }
    }

    /// Photos and videos nearly fill their bubble.
    private var isVisualMedia: Bool {
        switch message.body {
        case .photo, .video: true
        default: false
        }
    }

    var body: some View {
        if isBare {
            bare
        } else {
            bubble
        }
    }

    private var bubble: some View {
        let inset: CGFloat = isVisualMedia ? 6 : 0
        return BubbleLayout(spacing: 4) {
            if showsSenderName {
                Text(message.sender.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AccentPalette.color(for: message.sender.accentColorId))
                    .padding(.horizontal, inset)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let forwardedFrom = message.forwardedFrom {
                Text("Forwarded from \(forwardedFrom)")
                    .font(.caption.italic())
                    .opacity(0.75)
                    .padding(.horizontal, inset)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let reply = message.reply {
                ReplyQuote(reply: reply, isOutgoing: isOutgoing)
                    .padding(.horizontal, inset)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            footer
                .padding(.horizontal, inset)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, isVisualMedia ? 4 : 12)
        .padding(.vertical, isVisualMedia ? 4 : 7)
        .foregroundStyle(isOutgoing ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(
            isOutgoing ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.7)),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private var bare: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
            if let reply = message.reply {
                ReplyQuote(reply: reply, isOutgoing: false)
                    .padding(8)
                    .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            content
            footer
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.7), in: Capsule())
        }
    }

    @ViewBuilder private var content: some View {
        switch message.body {
        case .text(let text):
            richText(text)
        case .photo(let photo, let caption):
            VStack(alignment: .leading, spacing: 6) {
                PhotoView(photo: photo, files: files, onOpen: onOpen)
                mediaCaption(caption, width: MediaSize.fit(width: photo.image.width, height: photo.image.height).width)
            }
        case .video(let video, let caption):
            VStack(alignment: .leading, spacing: 6) {
                VideoView(video: video, files: files, onOpen: onOpen)
                mediaCaption(caption, width: MediaSize.fit(width: video.width, height: video.height).width)
            }
        case .videoNote(let note):
            VideoNoteView(note: note, files: files)
        case .sticker(let sticker):
            StickerView(sticker: sticker, files: files)
        case .document(let document, let caption):
            VStack(alignment: .leading, spacing: 6) {
                DocumentView(document: document, files: files, onOpen: onOpen)
                if !caption.isEmpty { richText(caption) }
            }
        case .voiceNote(let note, let caption):
            VStack(alignment: .leading, spacing: 6) {
                if let voice {
                    VoiceNoteView(messageId: message.id, note: note, isOutgoing: isOutgoing, files: files, voice: voice, onPlay: onPlayVoice)
                }
                if !caption.isEmpty { richText(caption) }
            }
        case .media(let label, let systemImage, let caption):
            VStack(alignment: .leading, spacing: 4) {
                Label(label, systemImage: systemImage)
                    .font(.callout.weight(.medium))
                if !caption.isEmpty { richText(caption) }
            }
        case .placeholder(let text):
            Text(text)
                .font(.callout.italic())
                .opacity(0.8)
        case .service(let text):
            Text(text)
        }
    }

    /// A caption wraps to the width of the photo or video above it.
    @ViewBuilder private func mediaCaption(_ text: RichText, width: CGFloat) -> some View {
        if !text.isEmpty {
            richText(text)
                .padding(.horizontal, 6)
                .frame(width: width, alignment: .leading)
        }
    }

    private func richText(_ text: RichText) -> some View {
        RichTextView(text: text, onAccent: isOutgoing)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if message.isEdited {
                Text("edited")
            }
            Text(message.date.formatted(date: .omitted, time: .shortened))
            if isOutgoing { statusIcon }
        }
        .font(.caption2)
        .opacity(0.7)
    }

    @ViewBuilder private var statusIcon: some View {
        switch message.status {
        case .sending:
            Image(systemName: "clock")
        case .failed(let reason):
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .help("Not sent: \(reason)")
        case .sent:
            // One check when sent, two when read.
            HStack(spacing: -6) {
                Image(systemName: "checkmark")
                if isRead { Image(systemName: "checkmark") }
            }
            .help(isRead ? "Read" : "Sent")
        }
    }
}

/// Stacks a bubble's parts vertically and makes the bubble exactly as wide as its widest part,
/// up to the space offered. (A VStack with a trailing-aligned footer would stretch every bubble to
/// full width.) Parts with `.frame(maxWidth: .infinity, alignment:)` then align within it.
struct BubbleLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = width(for: proposal, subviews: subviews)
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for subview in subviews {
            let size = ProposedViewSize(width: bounds.width, height: nil)
            let height = subview.sizeThatFits(size).height
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height + spacing
        }
    }

    private func width(for proposal: ProposedViewSize, subviews: Subviews) -> CGFloat {
        let available = proposal.width ?? .infinity
        return subviews.map { min($0.sizeThatFits(.unspecified).width, available) }.max() ?? 0
    }
}

/// Formatted message text: selectable, with spoilers hidden until clicked.
struct RichTextView: View {
    let text: RichText
    let onAccent: Bool
    @State private var revealsSpoilers = false

    var body: some View {
        let view = Text(AttributedString(text, onAccent: onAccent, revealsSpoilers: revealsSpoilers))
        if text.hasSpoilers && !revealsSpoilers {
            // Selectable text takes every click for itself, so it only becomes selectable once
            // you've clicked to reveal the spoiler.
            view
                .contentShape(Rectangle())
                .onTapGesture { revealsSpoilers = true }
                .help("Click to reveal")
        } else {
            view.textSelection(.enabled)
        }
    }
}

/// In groups: the sender's picture beside their last message, and matching space beside the others.
struct SenderAvatarSlot: View {
    let sender: MessageModel.Sender
    let showsAvatar: Bool
    let files: FileStore

    var body: some View {
        if showsAvatar {
            Avatar(
                title: sender.name,
                accentColorId: sender.accentColorId,
                photoFileId: sender.photoFileId,
                files: files,
                size: 28
            )
        } else {
            Color.clear.frame(width: 28, height: 1)
        }
    }
}

struct ReplyQuote: View {
    let reply: ReplyPreview
    let isOutgoing: Bool

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                if !reply.senderName.isEmpty {
                    Text(reply.senderName)
                        .font(.caption.weight(.semibold))
                }
                Text(reply.text)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .opacity(0.8)
        .padding(.vertical, 2)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension AttributedString {
    /// Renders Telegram formatting. `onAccent` adapts links and mentions to the blue outgoing bubble.
    init(_ rich: RichText, onAccent: Bool, revealsSpoilers: Bool) {
        var result = AttributedString(rich.text)
        let utf16 = rich.text.utf16
        for span in rich.spans {
            guard
                let lower = utf16.index(utf16.startIndex, offsetBy: span.range.lowerBound, limitedBy: utf16.endIndex),
                let upper = utf16.index(lower, offsetBy: span.range.count, limitedBy: utf16.endIndex),
                let start = AttributedString.Index(lower, within: result),
                let end = AttributedString.Index(upper, within: result),
                start < end
            else { continue }
            let range = start..<end
            switch span.style {
            case .bold: result.addIntent(.stronglyEmphasized, in: range)
            case .italic: result.addIntent(.emphasized, in: range)
            case .strikethrough: result.addIntent(.strikethrough, in: range)
            case .code, .pre: result.addIntent(.code, in: range)
            case .underline: result[range].underlineStyle = .single
            case .quote: result.addIntent(.emphasized, in: range)
            case .link(let url):
                result[range].link = url
                if onAccent {
                    result[range].foregroundColor = .white
                    result[range].underlineStyle = .single
                }
            case .mention:
                result[range].foregroundColor = onAccent ? .white : .accentColor
                if onAccent { result.addIntent(.stronglyEmphasized, in: range) }
            case .spoiler where !revealsSpoilers:
                // Hidden until you click the message.
                result[range].foregroundColor = .clear
                result[range].backgroundColor = .gray.opacity(0.45)
            case .spoiler:
                result[range].backgroundColor = .gray.opacity(0.2)
            }
        }
        self = result
    }

    /// Adds a style on top of whatever overlapping styles a range already has.
    fileprivate mutating func addIntent(_ intent: InlinePresentationIntent, in range: Range<AttributedString.Index>) {
        let runs = self[range].runs.map { ($0.range, $0.inlinePresentationIntent ?? []) }
        for (runRange, existing) in runs {
            self[runRange].inlinePresentationIntent = existing.union(intent)
        }
    }
}
