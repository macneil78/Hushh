import SwiftUI
import Testing
@testable import HushCore
@testable import HushUI

@MainActor
struct BubbleLayoutTests {
    private func renderedWidth(of text: String, offered: CGFloat = 560) -> CGFloat {
        let message = MessageModel(
            id: 1,
            date: .now,
            isOutgoing: true,
            sender: .init(id: 1, name: "Me", accentColorId: 0, photoFileId: nil),
            body: .text(RichText(text: text)),
            replyToMessageId: nil,
            reply: nil,
            forwardedFrom: nil,
            isEdited: false,
            status: .sent
        )
        let renderer = ImageRenderer(content: MessageBubble(message: message, showsSenderName: false, isRead: true, files: FileStore(), onOpen: { _ in }))
        renderer.proposedSize = ProposedViewSize(width: offered, height: nil)
        return renderer.nsImage?.size.width ?? 0
    }

    @Test func shortMessagesGetNarrowBubbles() {
        #expect(renderedWidth(of: "ok") < 150)
    }

    @Test func longMessagesWrapAtTheMaximumWidth() {
        let width = renderedWidth(of: String(repeating: "word ", count: 200))
        #expect(width > 400 && width <= 560)
    }
}
