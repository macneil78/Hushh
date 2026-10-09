import AppKit
import Foundation
import SwiftUI
import Testing
@testable import HushCore
@testable import HushUI

/// Draws a made-up conversation and sidebar with Hushh's real views, in light and dark mode. Set
/// HUSH_PREVIEW_DIR to a folder to get them as PNGs, for checking the design without opening
/// anyone's real chats:
///
///     HUSH_PREVIEW_DIR=/tmp/hushh-preview swift test --filter DesignPreviewTests
@MainActor
struct DesignPreviewTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func conversationAndSidebar(scheme: ColorScheme) throws {
        let conversation = render(SampleConversation(), width: 640, scheme: scheme)
        let sidebar = render(SampleSidebar(), width: 300, scheme: scheme)
        #expect((conversation?.size.height ?? 0) > 300)
        #expect((sidebar?.size.height ?? 0) > 200)
        guard let folder = ProcessInfo.processInfo.environment["HUSH_PREVIEW_DIR"] else { return }
        let directory = URL(filePath: folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = scheme == .dark ? "dark" : "light"
        try png(conversation).write(to: directory.appending(path: "conversation-\(suffix).png"))
        try png(sidebar).write(to: directory.appending(path: "sidebar-\(suffix).png"))
    }

    private func render(_ view: some View, width: CGFloat, scheme: ColorScheme) -> NSImage? {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        var image: NSImage?
        // Dynamic colors resolve against the current appearance while drawing.
        appearance?.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view
                .frame(width: width)
                .environment(\.colorScheme, scheme))
            renderer.scale = 2
            image = renderer.nsImage
        }
        return image
    }

    private func png(_ image: NSImage?) throws -> Data {
        let data = try #require(image?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
        return data
    }
}

private enum Sample {
    static let me = MessageModel.Sender(id: 1, name: "Me", accentColorId: 0, photoFileId: nil)
    static let anna = MessageModel.Sender(id: 2, name: "Anna Petrova", accentColorId: 1, photoFileId: nil)
    static let max = MessageModel.Sender(id: 3, name: "Max", accentColorId: 4, photoFileId: nil)
    static let now = Date(timeIntervalSinceReferenceDate: 812_000_000)

    static func message(
        _ id: Int64,
        _ text: String,
        from sender: MessageModel.Sender,
        minutes: Double,
        reply: ReplyPreview? = nil,
        reactions: [Reaction] = [],
        status: MessageModel.Status = .sent,
        isEdited: Bool = false
    ) -> MessageModel {
        var message = MessageModel(
            id: id,
            date: now + minutes * 60,
            isOutgoing: sender.id == me.id,
            sender: sender,
            body: .text(RichText(text: text)),
            replyToMessageId: nil,
            reply: reply,
            forwardedFrom: nil,
            isEdited: isEdited,
            status: status
        )
        message.reactions = reactions
        return message
    }
}

/// One-on-one chat, then a group, covering tails, Tapbacks, replies, "Edited", delivery and typing.
private struct SampleConversation: View {
    private let files = FileStore()

    var body: some View {
        VStack(spacing: 0) {
            TimestampHeading(date: Sample.now)
            row(Sample.message(1, "Hey! Are we still on for tonight?", from: Sample.anna, minutes: 0), first: true, last: false)
            row(Sample.message(2, "I booked a table at 8 🍝", from: Sample.anna, minutes: 1), first: false, last: true)
            row(Sample.message(3, "Yes! See you there", from: Sample.me, minutes: 2, reactions: [Reaction(kind: .emoji("❤️"), count: 1, isChosen: false)]), first: true, last: false)
            row(Sample.message(
                4,
                "Can you send me the address? Last time I walked around the block twice before I found the door.",
                from: Sample.me,
                minutes: 2.5,
                isEdited: true
            ), first: false, last: true)
            row(Sample.message(
                5,
                "Sure, it's on Rue Oberkampf, next to the bakery",
                from: Sample.anna,
                minutes: 3,
                reply: ReplyPreview(senderName: "You", text: "Can you send me the address?"),
                reactions: [Reaction(kind: .emoji("\u{2764}"), count: 1, isChosen: true)]  // Telegram's bare heart
            ), first: true, last: true)
            row(Sample.message(6, "Perfect, thanks!", from: Sample.me, minutes: 4), first: true, last: true, isLatest: true)
            TimestampHeading(date: Sample.now + 3 * 3600)
            row(Sample.message(7, "Who's bringing the speaker?", from: Sample.max, minutes: 180), first: true, last: true, isGroup: true)
            row(Sample.message(8, "I can", from: Sample.anna, minutes: 181), first: true, last: false, isGroup: true)
            row(Sample.message(9, "It's charged 🔋", from: Sample.anna, minutes: 181.5), first: false, last: true, isGroup: true)
            row(Sample.message(10, "This one didn't go through", from: Sample.me, minutes: 182, status: .failed("No connection")), first: true, last: true)
            TypingBubble()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(MessagesStyle.background)
    }

    private func row(_ message: MessageModel, first: Bool, last: Bool, isGroup: Bool = false, isLatest: Bool = false) -> some View {
        MessageChrome(
            lead: message,
            isFirstInGroup: first,
            isLastInGroup: last,
            isGroup: isGroup,
            isEdited: message.isEdited,
            delivery: DeliveryStatus.State(for: [message], isRead: true, isLatest: isLatest),
            reactions: message.reactions,
            // The react button only shows on hover, and the renderer can't draw its glass.
            canReact: false,
            files: files,
            onTapback: {}
        ) {
            MessageBubble(message: message, hasTail: last, files: files, onOpen: { _ in })
        }
    }
}

/// Rows: pinned, unread, muted, a mention, a draft, a channel.
private struct SampleSidebar: View {
    private let files = FileStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Mum", "Call me when you're free ❤️", "15:02", nil, pinned: true, accent: 5)
            row("Lucas Martin", "See you tomorrow then. I'll bring the charger you left at mine last week.", "14:20", .unread, accent: 2)
            row("Climbing crew", "Max: Who's bringing the speaker?", "13:05", .muted, muted: true, accent: 3)
            row("Sofia", "@you are you coming on Saturday?", "Mon", .mention, accent: 6)
            row("Dad", "\(Text("Draft:").foregroundStyle(.red)) call me when you land", "Sun", nil, accent: 0)
            row("Tech News", "Apple announces new MacBook Pro", "12.10.26", nil, channel: true, accent: 4)
        }
        .padding(.horizontal, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ name: String, _ preview: LocalizedStringKey, _ date: String, _ unread: ChatUnread?, muted: Bool = false, pinned: Bool = false, channel: Bool = false, accent: Int) -> some View {
        ChatRowLayout(title: name, preview: Text(preview), date: date, unread: unread, isMuted: muted, isPinned: pinned, isChannel: channel) {
            Avatar(title: name, accentColorId: accent, photoFileId: nil, files: files, size: 40)
        }
    }
}
