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
    /// Whether this is your latest message with nothing after it, which shows "Delivered" or "Read".
    let isLatest: Bool
    /// Just jumped to: flashes for a moment.
    var isHighlighted = false
    let conversation: ConversationModel
    let files: FileStore
    /// Swipe left to reply; nil where there's nothing to reply in.
    var swipe: SwipeToReply?
    @State private var isPickingReaction = false

    var body: some View {
        if case .service(let text) = message.body {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        } else {
            MessageChrome(
                lead: message,
                isFirstInGroup: isFirstInGroup,
                isLastInGroup: isLastInGroup,
                isGroup: isGroup,
                isEdited: message.isEdited,
                delivery: DeliveryStatus.State(for: [message], isRead: isRead, isLatest: isLatest),
                reactions: message.reactions,
                canReact: !conversation.reactionChoices.isEmpty,
                files: files,
                swipe: swipe,
                isHighlighted: isHighlighted,
                onTapback: { isPickingReaction = true }
            ) {
                MessageBubble(
                    message: message,
                    hasTail: isLastInGroup,
                    files: files,
                    onOpen: { conversation.quickLookURL = $0 },
                    onOpenMedia: { conversation.openViewer(message) },
                    voice: conversation.voice,
                    onPlayVoice: { conversation.playVoiceNote(message, url: $0) }
                )
                .help(message.date.formatted(date: .abbreviated, time: .shortened))
                .contextMenu { menu }
                .popover(isPresented: $isPickingReaction) { picker }
            }
        }
    }

    private var picker: some View {
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

    @ViewBuilder private var menu: some View {
        if !conversation.reactionChoices.isEmpty {
            Button("Tapback…") { isPickingReaction = true }
        }
        Button("Reply") { conversation.reply(to: message) }
        if message.canEditText {
            Button("Edit") { conversation.startEditing(message) }
        }
        if !message.plainText.isEmpty {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.plainText, forType: .string)
            }
        }
        if message.isViewableMedia {
            Button("View") { conversation.openViewer(message) }
        }
        if let fileId = message.fileId, let url = files.handle(for: fileId).localURL {
            if !message.isViewableMedia {
                Button("Quick Look") { conversation.quickLookURL = url }
            }
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

extension DeliveryStatus.State {
    /// What shows under a message or album: a failure always, otherwise "Delivered" or "Read"
    /// under your latest message only.
    init?(for messages: [MessageModel], isRead: Bool, isLatest: Bool) {
        guard messages.first?.isOutgoing == true else { return nil }
        for message in messages {
            if case .failed(let reason) = message.status {
                self = .failed(reason)
                return
            }
        }
        guard isLatest else { return nil }
        self = messages.contains { $0.status == .sending } ? .sending : (isRead ? .read : .delivered)
    }
}

/// Everything around a bubble, laid out as in Messages: in groups, the sender's name above the
/// first bubble and their picture beside the last; a Tapback badge on the top corner; "Edited"
/// and the delivery status underneath. Hovering shows a button to react.
struct MessageChrome<Bubble: View>: View {
    let lead: MessageModel
    let isFirstInGroup: Bool
    let isLastInGroup: Bool
    let isGroup: Bool
    let isEdited: Bool
    let delivery: DeliveryStatus.State?
    let reactions: [Reaction]
    let canReact: Bool
    let files: FileStore
    var swipe: SwipeToReply?
    /// Shows the time without hovering (for the design preview).
    var revealsTime = false
    /// Just jumped to: the row flashes.
    var isHighlighted = false
    /// Opens the reaction picker.
    let onTapback: () -> Void
    @ViewBuilder let bubble: Bubble
    @Environment(\.showsHoverDetails) private var showsHoverDetails
    @State private var isHovering = false

    private static var avatarSlot: CGFloat { SenderAvatarSlot.size + 8 }

    private var isOutgoing: Bool { lead.isOutgoing }
    private var showsSender: Bool { isGroup && !isOutgoing }
    /// Lines up captions under the bubble with its body, past the avatar and the tail.
    private var captionInset: CGFloat { (showsSender ? Self.avatarSlot : 0) + MessagesStyle.tailWidth + 6 }

    var body: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 3) {
            if showsSender && isFirstInGroup {
                Text(lead.sender.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, captionInset + 6)
            }
            HStack(alignment: .bottom, spacing: 8) {
                if showsSender {
                    SenderAvatarSlot(sender: lead.sender, showsAvatar: isLastInGroup, files: files)
                }
                if case .failed = delivery {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.red)
                        .padding(.bottom, 6)
                }
                // The react button sits on the side facing the middle of the window.
                HStack(spacing: 6) {
                    if isOutgoing { reactButton }
                    bubble
                        .overlay(alignment: isOutgoing ? .topLeading : .topTrailing) {
                            if !reactions.isEmpty {
                                // On the bubble's top corner, mostly above it, as Tapbacks sit.
                                TapbackBadge(reactions: reactions, onTap: onTapback)
                                    .fixedSize()
                                    .offset(x: isOutgoing ? -14 : 14, y: -17)
                            }
                        }
                        // Right at the bubble's edge, where the react button and time give way.
                        .modifier(SwipeReplyArrow(id: lead.id, swipe: swipe))
                    if !isOutgoing { reactButton }
                }
                // The time, while the pointer is over the message: beside it, toward the middle
                // of the window, without moving anything.
                .overlay(alignment: isOutgoing ? .leading : .trailing) {
                    Text(lead.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: 64, alignment: isOutgoing ? .trailing : .leading)
                        .offset(x: isOutgoing ? -70 : 70)
                        .opacity(isHovering || revealsTime ? 1 : 0)
                        .modifier(HiddenWhileSwiping(id: lead.id, swipe: swipe))
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: MessagesStyle.maxBubbleWidth + (showsSender ? Self.avatarSlot : 0), alignment: isOutgoing ? .trailing : .leading)
            if isEdited || delivery != nil {
                HStack(spacing: 6) {
                    if isEdited { Text("Edited") }
                    if let delivery { DeliveryStatus(state: delivery) }
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(isOutgoing ? .trailing : .leading, captionInset)
            }
        }
        // Bubbles never reach the far side of the window.
        .padding(isOutgoing ? .leading : .trailing, 60)
        .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
        .modifier(SwipeOffset(id: lead.id, swipe: swipe))
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(isHighlighted ? 0.16 : 0))
                .padding(.horizontal, -8)
                .padding(.vertical, -3)
                .animation(.easeOut(duration: isHighlighted ? 0.15 : 0.8), value: isHighlighted)
        }
        .padding(.top, (isFirstInGroup ? 10 : 2) + (reactions.isEmpty ? 0 : 14))
        .onHover { isHovering = $0 && showsHoverDetails }
    }

    /// Shown while the pointer is over the message; always takes its space, so nothing shifts.
    @ViewBuilder private var reactButton: some View {
        if canReact {
            Button("React", systemImage: "face.smiling", action: onTapback)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .glassEffect(.regular.interactive(), in: Circle())
                .help("React")
                .opacity(isHovering ? 1 : 0)
                .modifier(HiddenWhileSwiping(id: lead.id, swipe: swipe))
        }
    }
}

/// A message's bubble: text, files and voice in a blue or grey bubble; photos and videos on their
/// own with rounded corners, their caption in a bubble below; stickers bare.
struct MessageBubble: View {
    let message: MessageModel
    /// The last bubble of a run gets a tail.
    var hasTail = true
    let files: FileStore
    /// Opens a downloaded file in Quick Look.
    let onOpen: (URL) -> Void
    /// Opens a photo or video in Hushh's viewer.
    var onOpenMedia: () -> Void = {}
    /// Plays voice messages; nil where nothing can play (previews and tests).
    var voice: VoicePlayback?
    var onPlayVoice: (URL) -> Void = { _ in }

    private var isOutgoing: Bool { message.isOutgoing }
    private var alignment: HorizontalAlignment { isOutgoing ? .trailing : .leading }

    var body: some View {
        switch message.body {
        case .sticker, .videoNote:
            bare
        case .photo(let photo, let caption):
            visualMedia(caption: caption) {
                PhotoView(photo: photo, files: files, onOpen: onOpenMedia, cornerRadius: MessagesStyle.cornerRadius)
            }
        case .video(let video, let caption):
            visualMedia(caption: caption) {
                VideoView(video: video, files: files, onOpen: onOpenMedia, cornerRadius: MessagesStyle.cornerRadius)
            }
        default:
            bubble(hasTail: hasTail) {
                header
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Text in the blue or grey bubble, with a tail if it ends a run.
    private func bubble(hasTail: Bool, @ViewBuilder content: () -> some View) -> some View {
        BubbleLayout(spacing: 4) { content() }
            .bubblePadding(isOutgoing: isOutgoing)
            .foregroundStyle(isOutgoing ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(MessagesStyle.bubbleColor(isOutgoing: isOutgoing), in: BubbleShape(isOutgoing: isOutgoing, hasTail: hasTail))
    }

    /// "Forwarded from" and the message replied to, at the top of the bubble.
    @ViewBuilder private var header: some View {
        if let forwardedFrom = message.forwardedFrom {
            Text("Forwarded from \(forwardedFrom)")
                .font(.caption.italic())
                .opacity(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let reply = message.reply {
            ReplyQuote(reply: reply, isOutgoing: isOutgoing)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var hasHeader: Bool { message.forwardedFrom != nil || message.reply != nil }

    /// A photo or video stands on its own, as in Messages; its caption follows in a bubble.
    private func visualMedia(caption: RichText, @ViewBuilder media: () -> some View) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            if hasHeader {
                bubble(hasTail: false) { header }
            }
            media()
                .padding(isOutgoing ? .trailing : .leading, MessagesStyle.tailWidth)
            if !caption.isEmpty {
                bubble(hasTail: hasTail) { richText(caption) }
            }
        }
    }

    private var bare: some View {
        VStack(alignment: alignment, spacing: 4) {
            if let reply = message.reply {
                ReplyQuote(reply: reply, isOutgoing: false)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(MessagesStyle.incoming, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            content
            if case .videoNote = message.body {
                TranscriptText(message: message, inBubble: true)
            }
        }
        .padding(isOutgoing ? .trailing : .leading, MessagesStyle.tailWidth)
    }

    @ViewBuilder private var content: some View {
        switch message.body {
        case .text(let text):
            richText(text)
        case .photo(let photo, _):
            PhotoView(photo: photo, files: files, onOpen: onOpenMedia, cornerRadius: MessagesStyle.cornerRadius)
        case .video(let video, _):
            VideoView(video: video, files: files, onOpen: onOpenMedia, cornerRadius: MessagesStyle.cornerRadius)
        case .videoNote(let note):
            VideoNoteView(note: note, files: files)
                .overlay(alignment: .bottomTrailing) {
                    TranscribeButton(message: message)
                }
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
                    HStack(spacing: 8) {
                        VoiceNoteView(messageId: message.id, note: note, isOutgoing: isOutgoing, files: files, voice: voice, onPlay: onPlayVoice)
                        TranscribeButton(message: message, onAccent: isOutgoing)
                    }
                }
                TranscriptText(message: message)
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

    private func richText(_ text: RichText) -> some View {
        RichTextView(text: text, onAccent: isOutgoing)
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
    static let size: CGFloat = 28

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
                size: Self.size
            )
        } else {
            Color.clear.frame(width: Self.size, height: 1)
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
