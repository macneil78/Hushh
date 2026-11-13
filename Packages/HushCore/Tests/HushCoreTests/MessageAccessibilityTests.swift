import AppKit
import SwiftUI
import Testing
@testable import HushCore
@testable import HushUI

/// What VoiceOver finds in a message, read from the real accessibility tree of a message hosted
/// in an invisible window, with the pointer elsewhere.
@MainActor
struct MessageAccessibilityTests {
    private static let me = MessageModel.Sender(id: 1, name: "Me", accentColorId: 0, photoFileId: nil)
    private static let anna = MessageModel.Sender(id: 2, name: "Anna Petrova", accentColorId: 1, photoFileId: nil)
    private static let reactions = [
        Reaction(kind: .emoji("❤️"), count: 2, isChosen: true),
        Reaction(kind: .emoji("👍"), count: 1, isChosen: false),
        Reaction(kind: .customEmoji(1), count: 3, isChosen: false),
        Reaction(kind: .paid, count: 5, isChosen: false),
    ]

    private func message(_ text: String, from sender: MessageModel.Sender, status: MessageModel.Status = .sent) -> MessageModel {
        var message = MessageModel(
            id: 1, date: Date(timeIntervalSinceReferenceDate: 812_000_000), isOutgoing: sender.id == Self.me.id,
            sender: sender, body: .text(RichText(text: text)), replyToMessageId: nil, reply: nil,
            forwardedFrom: nil, isEdited: false, status: status
        )
        message.reactions = Self.reactions
        return message
    }

    /// The accessibility elements in reading order, one line each: "role label/value".
    private func elements(of message: MessageModel, isGroup: Bool) async -> [String] {
        let files = FileStore()
        let view = MessageChrome(
            lead: message, isFirstInGroup: true, isLastInGroup: true, isGroup: isGroup, isEdited: false,
            delivery: DeliveryStatus.State(for: [message], isRead: false, isLatest: true),
            reactions: message.reactions, canReact: true, files: files, onTapback: {}
        ) {
            MessageBubble(message: message, hasTail: true, files: files, onOpen: { _ in })
        }
        .padding(30)
        .frame(width: 640, height: 260, alignment: .top)
        TestWindow.enableAccessibility()
        let window = TestWindow.host(view, width: 640, height: 260)
        defer { TestWindow.close(window) }
        await TestWindow.settle(0.6)
        return TestWindow.accessibilityElements(in: window.contentView!).map(\.line)
    }

    @Test func messagesReadInOrderWithTimeReactionsAndReactButton() async {
        let lines = await elements(of: message("Hello there", from: Self.anna), isGroup: true)
        let joined = lines.joined(separator: "\n")
        let time = Date(timeIntervalSinceReferenceDate: 812_000_000).formatted(date: .omitted, time: .shortened)
        // Sender, text, time, React button, then every reaction with yours marked; the time and
        // the React button are there without hovering.
        let expected = [
            "StaticText \"Anna Petrova\"",
            "StaticText \"Hello there\"",
            "StaticText \"\(time)\"",
            "Button \"React\"",
            "Button \"Reactions: ❤️ 2, you reacted; 👍 1; custom emoji 3; paid stars 5\"",
        ]
        #expect(lines == expected, "\(joined)")
        // The avatar's initials are not read between the name and the text.
        #expect(!lines.contains { $0.contains("\"AP\"") }, "initials read: \(joined)")
    }

    @Test func failedIconIsNotReadAsASymbolName() async {
        let lines = await elements(of: message("This one failed", from: Self.me, status: .failed("No connection")), isGroup: false)
        let joined = lines.joined(separator: "\n")
        #expect(!joined.contains("exclamationmark"), "\(joined)")
        #expect(joined.contains("Not Delivered"))
    }
}
