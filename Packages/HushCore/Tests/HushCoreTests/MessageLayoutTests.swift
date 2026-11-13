import AppKit
import SwiftUI
import Testing
@testable import HushCore
@testable import HushUI

/// Where things land in a message row, measured in a real hosted window.
@MainActor
struct MessageLayoutTests {
    private static let me = MessageModel.Sender(id: 1, name: "Me", accentColorId: 0, photoFileId: nil)
    private static let anna = MessageModel.Sender(id: 2, name: "Alexandra Maximiliana Konstantinopolskaya-Wolfeschlegelsteinhausen", accentColorId: 1, photoFileId: nil)

    private func row(_ text: String, from sender: MessageModel.Sender, isGroup: Bool, reactions: [Reaction]) -> some View {
        var message = MessageModel(
            id: 1, date: .now, isOutgoing: sender.id == Self.me.id, sender: sender, body: .text(RichText(text: text)),
            replyToMessageId: nil, reply: nil, forwardedFrom: nil, isEdited: false, status: .sent
        )
        message.reactions = reactions
        let files = FileStore()
        return MessageChrome(
            lead: message, isFirstInGroup: true, isLastInGroup: true, isGroup: isGroup, isEdited: false,
            delivery: nil, reactions: reactions, canReact: false, files: files, onTapback: {}
        ) {
            MessageBubble(message: message, hasTail: true, files: files, onOpen: { _ in })
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
    }

    /// The row's accessibility elements, placed in a window `width` points wide, and the window's
    /// bounds.
    private func layout(of view: some View, width: CGFloat, height: CGFloat = 260) async -> (elements: [TestWindow.Element], bounds: CGRect) {
        TestWindow.enableAccessibility()
        let window = TestWindow.host(view.frame(width: width, height: height, alignment: .top), width: width, height: height)
        defer { TestWindow.close(window) }
        await TestWindow.settle(0.6)
        return (TestWindow.accessibilityElements(in: window.contentView!), CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// On a short message, a wide Tapback badge stays inside the window, its count whole, and off
    /// the sender's name in groups. 340 points is the narrowest conversation.
    @Test(arguments: [(false, false), (true, false), (false, true)])
    func tapbackBadgeStaysInTheWindowAndOffTheName(isOutgoing: Bool, isGroup: Bool) async throws {
        let reactions = ["👍", "❤", "🔥"].map { Reaction(kind: .emoji($0), count: 4142, isChosen: false) }
        let (elements, bounds) = await layout(
            of: row("ok", from: isOutgoing ? Self.me : Self.anna, isGroup: isGroup, reactions: reactions), width: 340
        )
        // The only button: the row can't react, so it has no React button.
        let badge = try #require(elements.first { $0.role == "Button" })
        #expect(bounds.contains(badge.frame), "badge \(badge.frame) leaves \(bounds)")
        if isGroup {
            let name = try #require(elements.first { $0.line.contains("Konstantinopolskaya") })
            #expect(!name.frame.intersects(badge.frame), "badge \(badge.frame) covers the name \(name.frame)")
            // A long name stays on one line.
            #expect(name.frame.height < 20, "name is \(name.frame.height) high")
        }
    }

    @Test func rightToLeftFollowsTheFirstLetter() {
        #expect(RichText(text: "مرحبا! كيف حالك").isRightToLeft)
        #expect(RichText(text: "«שלום» world").isRightToLeft)
        #expect(RichText(text: "12:30 مع أحمد").isRightToLeft)
        #expect(!RichText(text: "Meeting at 10:30 בבית הקפה").isRightToLeft)
        #expect(!RichText(text: "👍 123").isRightToLeft)
    }

    @Test func onlyOneToThreeEmojiAreDrawnLarge() {
        for text in ["👍", "😂🎉🔥", "❤", "🇺🇦👨‍👩‍👧‍👦👍🏽"] {
            #expect(Emoji.isJumbo(RichText(text: text)), "\(text)")
        }
        for text in ["😂🎉🔥❤️", "ok 👍", "1", "#", "©", "", "👍 "] {
            #expect(!Emoji.isJumbo(RichText(text: text)), "\(text)")
        }
        #expect(!Emoji.isJumbo(RichText(text: "👍", spans: [.init(range: 0..<2, style: .spoiler)])))
    }
}
