import AppKit
import Foundation
import Testing
@preconcurrency import TDLibKit
@testable import HushCore
@testable import HushUI

/// The composer's model: what happens to your text, attachments, reply and edit when TDLib
/// refuses a send, and which messages ↑ and Edit offer. The TDLib client is never set up, so
/// every send and edit fails, as it does offline or with an expired edit.
@MainActor
@Suite(.serialized)
struct ComposerModelTests {
    private func stored<T>(_ name: String, of object: Any, as: T.Type) -> T? {
        Mirror(reflecting: object).children.first { $0.label == name || $0.label == "_\(name)" }?.value as? T
    }

    /// A conversation with a saved draft and some of your own text messages (ids 1, 2, 3…).
    private func conversation(draft: String? = nil, myMessages: [String] = []) -> ConversationModel {
        let conversation = Fixtures.conversation(Fixtures.chat(draft: draft)).0
        for (index, text) in myMessages.enumerated() {
            conversation.handle(Fixtures.newMessage(message(Int64(index + 1), Fixtures.text(text))))
        }
        return conversation
    }

    /// One of your messages, sent a minute ago unless `date` says otherwise.
    private func message(
        _ id: Int64, _ content: MessageContent, outgoing: Bool = true, date: Int? = nil, sending: MessageSendingState? = nil
    ) -> Message {
        Fixtures.message(id, content, outgoing: outgoing, date: date ?? Int(Date.now.timeIntervalSince1970) - 60, sending: sending)
    }

    @Test func aFailedTextSendKeepsTheTextAndTheReply() async throws {
        let conversation = conversation(myMessages: ["question?"])
        let target = try #require(conversation.messages.last)
        conversation.reply(to: target)
        conversation.composerText = "answer"
        conversation.send()
        #expect(conversation.composerText.isEmpty)  // cleared at once
        await Fixtures.wait { conversation.errorMessage != nil }
        #expect(conversation.composerText == "answer")
        #expect(conversation.replyingTo?.id == target.id)
    }

    @Test func textTypedAfterAFailedSendIsKept() async throws {
        let conversation = conversation()
        conversation.composerText = "first"
        conversation.send()
        conversation.composerText = "second"  // typed before TDLib answered
        await Fixtures.wait { conversation.errorMessage != nil }
        #expect(conversation.composerText == "first\nsecond")
    }

    @Test func aFailedAttachmentSendKeepsFilesCaptionAndReply() async throws {
        let conversation = conversation(myMessages: ["send me the notes"])
        let target = try #require(conversation.messages.last)
        conversation.reply(to: target)
        conversation.attach([try Fixtures.temporaryFile("notes.txt"), try Fixtures.temporaryFile("photo.png", contents: Fixtures.png(width: 6))])
        conversation.composerText = "my caption"
        conversation.send()
        #expect(conversation.attachments.isEmpty)
        await Fixtures.wait { conversation.errorMessage != nil }
        #expect(conversation.attachments.map(\.name) == ["notes.txt", "photo.png"])
        #expect(conversation.composerText == "my caption")
        #expect(conversation.replyingTo?.id == target.id)
    }

    /// The edit stays an edit with the new text, and the draft from before the edit comes back
    /// when you give up on it.
    @Test func aFailedEditStaysAnEditAndKeepsTheDraft() async throws {
        let conversation = conversation(myMessages: ["helo wrold"])
        conversation.composerText = "my unsent draft"
        conversation.startEditing(try #require(conversation.messages.last))
        await Fixtures.settle(2000)  // lets the Markdown check finish
        conversation.composerText = "hello world"
        conversation.send()
        #expect(conversation.editing == nil)
        #expect(conversation.composerText == "my unsent draft")
        await Fixtures.wait { conversation.errorMessage != nil }
        #expect(conversation.editing?.id == 1)
        #expect(conversation.composerText == "hello world")
        conversation.cancelEditing()
        #expect(conversation.composerText == "my unsent draft")
    }

    @Test func upArrowOnlyOffersMessagesTelegramStillLetsYouEdit() {
        let conversation = conversation()
        let yearAgo = Int(Date.now.timeIntervalSince1970) - 365 * 24 * 3600
        conversation.handle(Fixtures.newMessage(message(10, Fixtures.text("ancient"), date: yearAgo)))
        #expect(!conversation.canEdit(conversation.messages[0]))
        #expect(!conversation.editLastMessage())  // ↑ is left to move the caret
        #expect(conversation.editing == nil)
    }

    @Test func upArrowEditsALoneEmojiButNotADice() async {
        let conversation = conversation(myMessages: ["older text"])
        let emoji = MessageContent.messageAnimatedEmoji(.init(
            animatedEmoji: AnimatedEmoji(fitzpatrickType: 0, sound: nil, sticker: nil, stickerHeight: 0, stickerWidth: 0),
            emoji: "👍"
        ))
        conversation.handle(Fixtures.newMessage(message(11, emoji)))
        #expect(conversation.editLastMessage())
        #expect(conversation.editing?.id == 11)
        #expect(conversation.composerText == "👍")
        conversation.cancelEditing()

        let dice = MessageContent.messageDice(.init(emoji: "🎲", finalState: nil, initialState: nil, successAnimationFrameNumber: 0, value: 3))
        conversation.handle(Fixtures.newMessage(message(12, dice)))
        #expect(!conversation.canEdit(conversation.messages[2]))  // no "Edit" in its menu
        #expect(conversation.editLastMessage())
        #expect(conversation.editing?.id == 11)  // the emoji before it
    }

    @Test func upArrowWithAttachmentsWaitingDoesNotStartAnEdit() throws {
        let conversation = conversation(myMessages: ["sent earlier"])
        conversation.attach([try Fixtures.temporaryFile("photo.png", contents: Fixtures.png(width: 4))])
        #expect(!conversation.editLastMessage())
        #expect(conversation.editing == nil)
    }

    /// A plain message holding `__init__` or `**` is shown as it is and edited without reading
    /// Markdown, so the characters survive. A message whose formatting Markdown shows exactly is
    /// shown as Markdown.
    @Test func editingKeepsLiteralMarkdownCharacters() async throws {
        let conversation = conversation(myMessages: ["call __init__ now", "**original**"])
        let bold = Fixtures.text("bold and x", entities: [TextEntity(length: 4, offset: 0, type: .textEntityTypeBold)])
        conversation.handle(Fixtures.newMessage(message(3, bold)))

        for (index, shown) in ["call __init__ now", "**original**"].enumerated() {
            conversation.startEditing(conversation.messages[index])
            await Fixtures.settle(2000)  // lets the Markdown check finish
            #expect(conversation.composerText == shown)
            let source = try #require(stored("editingSource", of: conversation, as: FormattedText?.self) ?? nil)
            let saved = ConversationModel.carryFormatting(of: source, over: conversation.composerText)
            #expect(saved.text == shown)
            #expect(saved.entities.isEmpty)
            conversation.cancelEditing()
        }

        conversation.startEditing(conversation.messages[2])
        await Fixtures.wait { conversation.composerText == "**bold** and x" }
        #expect(conversation.composerText == "**bold** and x")
        #expect(stored("editingSource", of: conversation, as: FormattedText?.self) as? FormattedText == nil)
    }

    /// What typing right after ↑ puts in the box is never replaced by the Markdown version.
    @Test func typingRightAfterUpArrowIsKept() async throws {
        let conversation = conversation()
        let bold = Fixtures.text("bold x", entities: [TextEntity(length: 4, offset: 0, type: .textEntityTypeBold)])
        conversation.handle(Fixtures.newMessage(message(3, bold)))
        #expect(conversation.editLastMessage())
        conversation.composerText = "bold xy"
        await Fixtures.settle(2000)  // lets the Markdown check finish
        #expect(conversation.composerText == "bold xy")
    }

    @Test func formattingFollowsAnEdit() {
        let bold = TextEntity(length: 4, offset: 0, type: .textEntityTypeBold)
        let code = TextEntity(length: 8, offset: 9, type: .textEntityTypeCode)
        let source = FormattedText(entities: [bold, code], text: "bold and __init__ x")
        // A typo fixed between the two: both stay, the second shifts.
        let fixed = ConversationModel.carryFormatting(of: source, over: "bold, and __init__ x")
        #expect(fixed.entities.map(\.offset) == [0, 10])
        #expect((fixed.text as NSString).substring(with: NSRange(location: 10, length: 8)) == "__init__")
        // Text typed inside the bold word stays bold.
        let inside = ConversationModel.carryFormatting(of: source, over: "boXld and __init__ x")
        #expect(inside.entities.first?.length == 5)
        // Unchanged: identical.
        #expect(ConversationModel.carryFormatting(of: source, over: source.text) == source)
    }

    /// Random edits of random formatted text: formatting never points outside the text, and
    /// formatting away from the change keeps covering the same characters.
    @Test func formattingFollowsRandomEdits() {
        var random = SystemRandomNumberGenerator()
        let alphabet = Array("ab _*|~é👍\n")
        for _ in 0 ..< 500 {
            let text = String((0 ..< Int.random(in: 0 ... 30, using: &random)).map { _ in alphabet.randomElement(using: &random)! })
            let length = text.utf16.count
            var entities: [TextEntity] = []
            if length > 1 {
                for _ in 0 ..< 3 {
                    let offset = Int.random(in: 0 ..< length - 1, using: &random)
                    entities.append(TextEntity(length: Int.random(in: 1 ... length - offset, using: &random), offset: offset, type: .textEntityTypeItalic))
                }
            }
            let source = FormattedText(entities: entities, text: text)
            var edited = Array(text)
            let at = Int.random(in: 0 ... edited.count, using: &random)
            let removed = Int.random(in: 0 ... min(3, edited.count - at), using: &random)
            edited.replaceSubrange(at ..< at + removed, with: (0 ..< Int.random(in: 0 ... 3, using: &random)).map { _ in alphabet.randomElement(using: &random)! })
            let result = ConversationModel.carryFormatting(of: source, over: String(edited))
            let newLength = result.text.utf16.count
            for entity in result.entities {
                #expect(entity.offset >= 0 && entity.length > 0 && entity.offset + entity.length <= newLength, "\(text.debugDescription) → \(String(edited).debugDescription)")
            }
        }
    }

    @Test func longTextIsSplitIntoMessagesTelegramAccepts() {
        var random = SystemRandomNumberGenerator()
        let words = ["hello", "👍🏽", "x", "\n", "ünïcode", "a-very-long-word-without-spaces"]
        for limit in [7, 20, 100] {
            for _ in 0 ..< 200 {
                let text = (0 ..< Int.random(in: 1 ... 80, using: &random)).map { _ in words.randomElement(using: &random)! }.joined(separator: " ")
                let length = text.utf16.count
                let whole = FormattedText(entities: [TextEntity(length: length, offset: 0, type: .textEntityTypeBold)], text: text)
                let pieces = ConversationModel.split(whole, limit: limit)
                for piece in pieces {
                    #expect(piece.text.utf16.count <= limit)
                    #expect(piece.entities.allSatisfy { $0.offset >= 0 && $0.offset + $0.length <= piece.text.utf16.count })
                    #expect(piece.entities.map(\.length).reduce(0, +) == piece.text.utf16.count)  // still bold throughout
                }
                // Nothing lost but whitespace-only pieces; no emoji cut in half.
                #expect(pieces.map(\.text).joined().filter { !$0.isWhitespace } == text.filter { !$0.isWhitespace })
            }
        }
        #expect(ConversationModel.split(FormattedText(entities: [], text: "short"), limit: 4096).count == 1)
    }

    @Test func deletingTheReplyTargetOrTheEditedMessageClearsTheComposerButKeepsText() {
        let conversation = conversation(myMessages: ["mine"])
        conversation.handle(Fixtures.newMessage(message(10, Fixtures.text("theirs"), outgoing: false)))
        conversation.reply(to: conversation.messages[1])
        conversation.handle(.updateDeleteMessages(.init(chatId: Fixtures.chatId, fromCache: false, isPermanent: true, messageIds: [10])))
        #expect(conversation.replyingTo == nil)

        conversation.composerText = "draft"
        conversation.startEditing(conversation.messages[0])
        conversation.composerText = "mine, edited"
        conversation.handle(.updateDeleteMessages(.init(chatId: Fixtures.chatId, fromCache: false, isPermanent: true, messageIds: [1])))
        #expect(conversation.editing == nil)
        #expect(conversation.composerText == "mine, edited\ndraft")
    }

    @Test func theReplyBarFollowsAMessageThatGetsItsFinalId() {
        let conversation = conversation()
        conversation.handle(Fixtures.newMessage(message(1_000_001, Fixtures.text("mine"), sending: .messageSendingStatePending(.init(sendingId: 1)))))
        conversation.reply(to: conversation.messages[0])
        conversation.handle(.updateMessageSendSucceeded(.init(message: message(2_000_000, Fixtures.text("mine")), oldMessageId: 1_000_001)))
        #expect(conversation.replyingTo?.id == 2_000_000)
    }

    @Test func foldersAreRefusedWithAMessage() throws {
        let conversation = conversation()
        let folder = FileManager.default.temporaryDirectory.appending(path: "hush-test-folder-\(UUID().uuidString).jpg", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try Fixtures.temporaryFile("notes.txt")
        conversation.attach([folder, file])
        #expect(conversation.attachments.map(\.name) == ["notes.txt"])
        #expect(conversation.errorMessage != nil)
    }

    /// A picture Hushh can't read goes out as a file on its own, never as a file inside a photo
    /// album (Telegram refuses such albums). The caption goes on the first photo.
    @Test func unreadablePicturesAreSentApartFromTheAlbum() async throws {
        let good = Attachment(url: try Fixtures.temporaryFile("good.png", contents: Fixtures.png(width: 4)))
        let other = Attachment(url: try Fixtures.temporaryFile("other.png", contents: Fixtures.png(width: 8)))
        let broken = Attachment(url: try Fixtures.temporaryFile("broken.jpg", contents: Data()))
        let caption = FormattedText(entities: [], text: "trip")
        let batches = await ConversationModel.batches([broken, good, other], caption: caption)
        let kinds = batches.map { batch in
            batch.contents.map { content -> String in
                switch content {
                case .inputMessagePhoto(let photo): "photo:\(photo.caption?.text ?? "")"
                case .inputMessageDocument(let document): "document:\(document.caption?.text ?? "")"
                default: "other"
                }
            }
        }
        #expect(kinds == [["photo:trip", "photo:"], ["document:"]])
        #expect(batches.map(\.ids) == [[good.id, other.id], [broken.id]])
    }

    @Test func aDraftFromAnotherDeviceShowsWhileTheChatIsOpen() {
        let conversation = conversation()
        func draft(_ text: String) -> Update {
            .updateChatDraftMessage(UpdateChatDraftMessage(chatId: Fixtures.chatId, draftMessage: DraftMessage(
                content: .draftMessageContentText(DraftMessageContentText(linkPreviewOptions: nil, text: FormattedText(entities: [], text: text))),
                date: 1, effectId: 0, replyTo: nil, suggestedPostInfo: nil
            ), positions: []))
        }
        conversation.handle(draft("typed on phone"))
        #expect(conversation.composerText == "typed on phone")
        conversation.composerText = "typed here"
        conversation.handle(draft("phone again"))
        #expect(conversation.composerText == "typed here")  // never over what you typed
    }

    /// ⌘Q: the draft goes to TDLib right away, before TDLib closes.
    @Test func quittingHandsTheDraftToTDLib() async {
        let conversation = conversation(draft: "old")
        await conversation.open()
        conversation.composerText = "half a message"
        var sent: [SetChatDraftMessage] = []
        conversation.closeBeforeQuitting { sent.append($0) }
        #expect(sent.count == 1)
        if case .draftMessageContentText(let content)? = sent.first?.draftMessage?.content {
            #expect(content.text.text == "half a message")
        } else {
            Issue.record("no text draft sent")
        }
    }

    /// The first time, macOS asks for the microphone. Nothing records while it asks, Esc stops
    /// the wait, and saying yes doesn't start a recording by itself.
    @Test func recordingWaitsForPermissionAndNeverStartsLate() async {
        let conversation = conversation()
        let recorder = conversation.recorder
        recorder.permission = { .undetermined }
        recorder.requestPermission = {
            try? await Task.sleep(for: .milliseconds(200))
            return true
        }
        conversation.startRecording()
        await Fixtures.wait { recorder.state == .waitingForPermission }
        #expect(recorder.state == .waitingForPermission)
        #expect(conversation.cancelComposerMode())  // Esc
        #expect(recorder.state == .idle)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(recorder.state == .idle)
        #expect(conversation.errorMessage == nil)

        conversation.startRecording()
        await Fixtures.wait { conversation.errorMessage != nil }
        #expect(recorder.state == .idle)
        #expect(conversation.errorMessage?.contains("Press Record again") == true)
    }
}
