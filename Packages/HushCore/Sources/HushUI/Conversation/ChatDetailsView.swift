import AppKit
import HushCore
import SwiftUI

/// A chat's info and shared media on a page of its own, in place of the conversation, as
/// Telegram's and Signal's desktop apps show it: who it is, then photos and videos, files, links,
/// voice messages and music, newest first and grouped by month.
struct ChatDetailsView: View {
    let conversation: ConversationModel
    let chat: ChatItem
    let files: FileStore
    let chats: ChatStore
    let onClose: () -> Void
    @State private var kind = SharedMediaKind.media
    @FocusState private var isFocused: Bool

    private var media: SharedMediaModel { conversation.sharedMedia }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                header
                Section {
                    content
                } header: {
                    tabs
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 16)
        }
        .background(MessagesStyle.background)
        .environment(\.conversation, conversation)
        // Takes the keyboard from the message box underneath; Esc goes back to the chat.
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
        .task { await media.loadCounts() }
        .task(id: kind) {
            if media.items(kind).isEmpty { await media.loadMore(kind) }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            AvatarView(item: chat, files: files, size: 88)
                .padding(.bottom, 6)
            Text(chat.displayTitle)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            let subtitle = ConversationView.subtitle(for: chat, chats: chats)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .padding(.bottom, 18)
    }

    /// Pill tabs, as in Telegram, pinned to the top while the list scrolls.
    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(SharedMediaKind.allCases) { tab in
                Button { kind = tab } label: {
                    Text(tab.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(kind == tab ? Color.accentColor : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(kind == tab ? Color.accentColor.opacity(0.15) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(MessagesStyle.background)
    }

    @ViewBuilder private var content: some View {
        let items = media.items(kind)
        Text(media.counts[kind].map(kind.countText) ?? " ")
            .font(.caption)
            .foregroundStyle(.secondary)
        if items.isEmpty {
            if media.hasMore(kind) {
                ProgressView()
                    .padding(40)
            } else {
                ContentUnavailableView(emptyTitle, systemImage: emptyImage)
                    .padding(.top, 30)
            }
        } else {
            ForEach(Self.months(items), id: \.start) { month in
                Text(month.start.formatted(.dateTime.month(.wide).year()))
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                if kind == .media {
                    grid(month.items)
                } else {
                    ForEach(month.items) { message in
                        row(for: message)
                        Divider()
                            .padding(.leading, 12)
                    }
                }
            }
            if media.hasMore(kind) {
                // At the end of what's loaded, fetch the next page, and again while this
                // stays in view (a page that doesn't fill the window).
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .task(id: items.count) {
                        await media.loadMore(kind)
                    }
            }
        }
    }

    private func grid(_ items: [MessageModel]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 2)], spacing: 2) {
            ForEach(items) { message in
                MediaThumbnail(message: message, files: files)
                    .onTapGesture { conversation.openViewer(message, fromSharedMedia: true) }
                    .help(message.date.formatted(date: .abbreviated, time: .shortened))
                    .contextMenu { menu(for: message) }
            }
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder private func row(for message: MessageModel) -> some View {
        Group {
            switch kind {
            case .links:
                LinkRow(message: message)
            case .voice:
                VStack(alignment: .leading, spacing: 6) {
                    byline(message)
                    if case .voiceNote(let note, _) = message.body {
                        HStack(spacing: 8) {
                            VoiceNoteView(
                                messageId: message.id,
                                note: note,
                                isOutgoing: false,
                                files: files,
                                voice: conversation.voice,
                                onPlay: { conversation.playVoiceNote(message, url: $0) }
                            )
                            TranscribeButton(message: message)
                        }
                        TranscriptText(message: message)
                    }
                }
            default:
                VStack(alignment: .leading, spacing: 4) {
                    if case .document(let document, _) = message.body {
                        DocumentView(document: document, files: files) { conversation.quickLookURL = $0 }
                    }
                    byline(message)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu { menu(for: message) }
    }

    private func byline(_ message: MessageModel) -> some View {
        Text("\(message.isOutgoing ? "You" : message.sender.name) · \(message.date.formatted(date: .abbreviated, time: .shortened))")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    @ViewBuilder private func menu(for message: MessageModel) -> some View {
        Button("Show in Chat") {
            onClose()
            Task { await conversation.reveal(message.id) }
        }
        if message.isViewableMedia {
            Button("View") { conversation.openViewer(message, fromSharedMedia: true) }
        }
        ForEach(message.links, id: \.self) { url in
            Button("Copy \(url.host() ?? "Link")") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
        if let fileId = message.fileId, let url = files.handle(for: fileId).localURL {
            Button("Save As…") { FileActions.saveAs(url, suggestedName: url.lastPathComponent) }
        }
    }

    private var emptyTitle: String {
        switch kind {
        case .media: "No Photos or Videos"
        case .files: "No Files"
        case .links: "No Links"
        case .voice: "No Voice Messages"
        case .music: "No Music"
        }
    }

    private var emptyImage: String {
        switch kind {
        case .media: "photo.on.rectangle"
        case .files: "doc"
        case .links: "link"
        case .voice: "waveform"
        case .music: "music.note"
        }
    }

    /// Newest first, a group per calendar month.
    static func months(_ items: [MessageModel], calendar: Calendar = .current) -> [(start: Date, items: [MessageModel])] {
        var months: [(start: Date, items: [MessageModel])] = []
        for item in items {
            let start = calendar.dateInterval(of: .month, for: item.date)?.start ?? item.date
            if months.last?.start == start {
                months[months.count - 1].items.append(item)
            } else {
                months.append((start, [item]))
            }
        }
        return months
    }
}

/// A square tile in the media grid: the photo, or the video's poster with its length.
struct MediaThumbnail: View {
    let message: MessageModel
    let files: FileStore

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                switch message.body {
                case .photo(let photo, _):
                    // The small preview, not the size shown in chat bubbles.
                    RemoteImage(source: photo.thumbnail, minithumbnail: photo.minithumbnail, files: files, maxPixelSize: 320)
                case .video(let video, _):
                    RemoteImage(source: video.thumbnail, minithumbnail: video.minithumbnail, files: files, maxPixelSize: 320)
                default:
                    Rectangle().fill(.quaternary)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if case .video(let video, _) = message.body {
                    Text(video.isGIF ? "GIF" : Duration.seconds(video.duration).formatted(.time(pattern: .minuteSecond)))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            .clipped()
            .contentShape(Rectangle())
    }
}

/// A message's links: the site, each address, and the text around them.
struct LinkRow: View {
    let message: MessageModel

    private var links: [URL] { message.links }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(Self.site(of: links.first).prefix(1).uppercased())
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.site(of: links.first))
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                ForEach(links, id: \.self) { url in
                    // Link-styled text: clicking opens it in the browser.
                    Text(AttributedString(url.absoluteString, attributes: AttributeContainer().link(url)))
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                let text = message.plainText
                if !links.contains(where: { $0.absoluteString == text }) {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text("\(message.isOutgoing ? "You" : message.sender.name) · \(message.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// "github.com" for https://www.github.com/…
    static func site(of url: URL?) -> String {
        guard let host = url?.host(), !host.isEmpty else { return "Link" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
