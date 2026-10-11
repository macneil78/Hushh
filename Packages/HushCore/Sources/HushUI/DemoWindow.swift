import AVFoundation
import HushCore
import SwiftUI

/// Hushh's window with made-up chats, for screenshots, built from the app's own views. Launch
/// with `-HushhDemo YES`: Hushh then doesn't log in to Telegram at all, so nothing private can
/// end up in a picture. It follows the system's appearance, like the app; `-HushhDemoDark YES` or
/// `-HushhDemoLight YES` picks one.
struct DemoWindow: View {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "HushhDemo") }
    static var colorScheme: ColorScheme? {
        if UserDefaults.standard.bool(forKey: "HushhDemoDark") { return .dark }
        if UserDefaults.standard.bool(forKey: "HushhDemoLight") { return .light }
        return nil
    }

    @State private var files = FileStore()
    @State private var voice = VoicePlayback()
    @State private var messages: [MessageModel] = []
    @State private var searchText = ""
    @State private var selection: Int64? = DemoData.openChatId

    private static let photoSize = CGSize(width: 1200, height: 900)

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(DemoData.chats) { chat in
                    row(chat).tag(chat.id)
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
            .navigationSplitViewColumnWidth(min: 250, ideal: 310, max: 420)
        } detail: {
            conversation
        }
        .preferredColorScheme(Self.colorScheme)
        // No hover details: the pointer is over the window when you capture it.
        .environment(\.showsHoverDetails, false)
        .task { prepare() }
    }

    private func row(_ chat: DemoData.Chat) -> some View {
        let unread: ChatUnread? = chat.isMention ? .mention : chat.isUnread ? (chat.isMuted ? .muted : .unread) : nil
        return ChatRowLayout(
            title: chat.title,
            preview: chat.isDraft ? Text("\(Text("Draft:").foregroundStyle(.red)) \(chat.preview)") : Text(chat.preview),
            date: ChatDate.short(chat.date),
            unread: unread,
            isMuted: chat.isMuted,
            isPinned: chat.isPinned,
            isChannel: false
        ) {
            Avatar(title: chat.title, accentColorId: chat.accentColorId, photoFileId: nil, files: files, size: 40)
                .overlay(alignment: .bottomTrailing) {
                    if chat.isOnline { OnlineDot() }
                }
        }
    }

    private var conversation: some View {
        let chat = DemoData.chats.first { $0.id == DemoData.openChatId }
        return ScrollView {
            VStack(spacing: 0) {
                ForEach(Timeline.build(messages, firstUnreadMessageId: nil)) { item in
                    timelineRow(item)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .defaultScrollAnchor(.bottom)
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .background(MessagesStyle.background)
        .navigationTitle(chat?.title ?? "")
        .navigationSubtitle(DemoData.openChatSubtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Chat Info", systemImage: "info.circle") {}
            }
        }
    }

    @ViewBuilder private func timelineRow(_ item: TimelineItem) -> some View {
        switch item {
        case .timestamp(let date):
            TimestampHeading(date: date)
        case .message(let message, let isFirst, let isLast):
            MessageChrome(
                lead: message,
                isFirstInGroup: isFirst,
                isLastInGroup: isLast,
                isGroup: false,
                isEdited: message.isEdited,
                delivery: DeliveryStatus.State(for: [message], isRead: true, isLatest: message.id == messages.last?.id),
                reactions: message.reactions,
                canReact: true,
                files: files,
                onTapback: {}
            ) {
                MessageBubble(message: message, hasTail: isLast, files: files, onOpen: { _ in }, voice: voice)
            }
        case .album, .unreadDivider:
            EmptyView()
        }
    }

    /// The message field as the app draws it: glass, with + on the left.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .glassEffect(.regular, in: Circle())
            HStack(spacing: 10) {
                Text("Message")
                    .foregroundStyle(.tertiary)
                Spacer()
                Image(systemName: "face.smiling")
                    .font(.system(size: 16))
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 13)
            .padding(.trailing, 10)
            .frame(height: 32)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    /// Draws the photo and records the voice message's sound, then fills in the conversation.
    private func prepare() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "hushh-demo", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let photo = folder.appending(path: "terrace.jpg")
        if (try? DemoData.drawPhoto(to: photo, size: Self.photoSize)) != nil {
            files.provide(photo, for: DemoData.photoFileId)
        }
        let sound = folder.appending(path: "voice.caf")
        if (try? Self.recordTone(to: sound)) != nil {
            files.provide(sound, for: DemoData.voiceFileId)
        }
        messages = DemoData.messages(photoSize: Self.photoSize)
    }

    /// Nine seconds of a soft hum, so the voice message plays something.
    private static func recordTone(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let frames = AVAudioFrameCount(9 * 16_000)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            let time = Float(index) / 16_000
            buffer.floatChannelData![0][index] = 0.15 * sin(2 * .pi * 220 * time) * (0.5 + 0.5 * sin(2 * .pi * 2 * time))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
