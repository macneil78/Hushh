import Foundation
import ImageIO
import Testing
@testable import HushAI
@testable import HushCore

@MainActor
struct CodexTests {
    private let anna = MessageModel.Sender(id: 2, name: "Anna", accentColorId: 0, photoFileId: nil)
    private let me = MessageModel.Sender(id: 1, name: "Me", accentColorId: 0, photoFileId: nil)

    private func message(_ id: Int64, _ text: String, outgoing: Bool = false, at date: Date = .now) -> MessageModel {
        MessageModel(
            id: id, date: date, isOutgoing: outgoing, sender: outgoing ? me : anna,
            body: .text(RichText(text: text)), replyToMessageId: nil, reply: nil,
            forwardedFrom: nil, isEdited: false, status: .sent
        )
    }

    @Test func catchUpSumsUpTheUnreadWithAFewBefore() {
        let messages = (1...40).map { message(Int64($0), "message \($0)") }
        let (chosen, unread) = ChatAssistant.messagesToSummarize(messages, firstUnreadId: 36)
        #expect(unread == 5)
        #expect(chosen.first?.id == 26)
        #expect(chosen.last?.id == 40)
    }

    @Test func withLittleUnreadCatchUpTakesTheLatestStretch() {
        let old = Date.now.addingTimeInterval(-5 * 86_400)
        let messages = (1...50).map { message(Int64($0), "message \($0)", at: old) }
        let (chosen, unread) = ChatAssistant.messagesToSummarize(messages, firstUnreadId: 50)
        #expect(unread == 0)
        #expect(chosen.count == 30)
        #expect(chosen.last?.id == 50)
    }

    @Test func transcriptNamesWhoSaidWhatAndDescribesMedia() {
        var voice = MessageModel(
            id: 3, date: .now, isOutgoing: false, sender: anna,
            body: .voiceNote(VoiceNoteMedia(fileId: 1, duration: 4, waveform: [], isListened: true, transcription: .done("Running late")), caption: RichText(text: "")),
            replyToMessageId: nil, reply: nil, forwardedFrom: nil, isEdited: false, status: .sent
        )
        voice.reply = ReplyPreview(senderName: "You", text: "Where are you?")
        let lines = ChatAssistant.transcript([message(1, "Where are you?", outgoing: true), voice]).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("] Me: Where are you?"))
        #expect(lines[1].hasSuffix("] Anna: (replying to You: \"Where are you?\") [voice message] Running late"))
    }

    @Test func draftsTakeWhatYouTypedAsTheHint() {
        let prompt = ChatAssistant.draftPrompt(chatTitle: "Anna", transcript: "[…] Anna: Dinner?", hint: "yes but at 8")
        #expect(prompt.contains("What I want to say: yes but at 8"))
        #expect(prompt.contains("chat with Anna"))
    }

    @Test func draftsLearnHowYouWriteToThisPerson() {
        let prompt = ChatAssistant.draftPrompt(chatTitle: "Mum", transcript: "[…] Mum: Ты где?", styleSamples: ["ок мам", "", "буду\nв 8"], hint: nil)
        #expect(prompt.contains("how I write to Mum:\n- ок мам\n- буду в 8"))
        #expect(!ChatAssistant.draftPrompt(chatTitle: "Mum", transcript: "", hint: nil).contains("how I write to"))
    }

    @Test func photosShownToCodexAreNumbered() {
        let image = ImageSource(fileId: 9, width: 800, height: 600)
        let photo = MessageModel(
            id: 7, date: .now, isOutgoing: false, sender: anna,
            body: .photo(PhotoMedia(image: image, largest: image, thumbnail: image, minithumbnail: nil), caption: RichText(text: "the view")),
            replyToMessageId: nil, reply: nil, forwardedFrom: nil, isEdited: false, status: .sent
        )
        #expect(ChatAssistant.transcript([photo], photoNumbers: [7: 2]).hasSuffix("] Anna: [Photo 2: the view]"))
        #expect(ChatAssistant.summaryPrompt(chatTitle: "Anna", transcript: "", unreadCount: 3, photoCount: 2).contains("[Photo 1] to [Photo 2] are attached"))
        #expect(!ChatAssistant.summaryPrompt(chatTitle: "Anna", transcript: "", unreadCount: 3).contains("attached"))
    }

    @Test func photosAreShrunkBeforeCodexSeesThem() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "codex-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appending(path: "big.jpg")
        try DemoData.drawPhoto(to: original, size: CGSize(width: 2400, height: 1800))
        let shrunk = Codex.shrink([original, folder.appending(path: "missing.jpg")], into: folder)
        #expect(shrunk.count == 1)
        let source = try #require(CGImageSourceCreateWithURL(shrunk[0] as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 768)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 576)
    }

    @Test func codexErrorsReadNicely() {
        let log = """
        OpenAI Codex v0.167.1
        ERROR: {"type":"error","error":{"message":"You've hit your usage limit.","type":"rate_limit"}}
        """
        #expect(Codex.reason(fromLog: log) == "Codex: You've hit your usage limit.")
        #expect(Codex.reason(fromLog: "Not logged in. Please run codex login") == "Codex isn't signed in. Run “codex login” in Terminal.")
        #expect(Codex.reason(fromLog: "") == "Codex didn't answer.")
    }
}
