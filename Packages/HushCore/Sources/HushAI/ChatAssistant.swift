import Foundation
import HushCore
import Observation

/// Codex's help in one chat: Catch Up (a summary of what you missed), Draft a Reply, Polish
/// what you've typed, and Translate a message. Each runs only when you ask, and sends Codex only
/// the messages it needs.
@MainActor @Observable
public final class ChatAssistant {
    public enum Work: Equatable, Sendable {
        case working
        case done(String)
        case failed(String)
    }

    /// Ways to rewrite the message box's text.
    public enum Polish: Equatable, Sendable {
        case fix
        case shorter
        case friendlier
        case formal
        case translate(Language)
    }

    public struct Language: Equatable, Hashable, Sendable, Identifiable {
        public let code: String
        /// In the Mac's language, for menus.
        public let name: String
        /// In English, for Codex.
        let englishName: String
        public var id: String { code }
    }

    /// Catch Up's summary, shown at the top of the chat.
    public private(set) var summary: Work?
    /// Translations shown under messages, by message id.
    public private(set) var translations: [Int64: Work] = [:]
    /// Codex is writing in the message box.
    public private(set) var isWriting = false
    /// The message box's text before Codex replaced it, for Undo.
    private var replacedText: String?
    /// What Codex put in the message box.
    private var writtenText: String?

    @ObservationIgnored private let conversation: ConversationModel
    @ObservationIgnored private let codex: Codex
    @ObservationIgnored private let files: FileStore
    @ObservationIgnored private let memory: ChatMemory?
    @ObservationIgnored private let chatTitle: String

    public init(conversation: ConversationModel, codex: Codex, files: FileStore, vault: LocalVault?, chatTitle: String) {
        self.conversation = conversation
        self.codex = codex
        self.files = files
        memory = vault.map(ChatMemory.init)
        self.chatTitle = chatTitle
    }

    /// The chat's memory to show Codex and have it update: nil when memory is off.
    private var currentMemory: String? {
        guard ChatMemory.isEnabled, let memory else { return nil }
        return memory.read(conversation.chatId)
    }

    /// Codex's answer without the memory part, which is saved.
    private func keepingMemory(_ answer: String) -> String {
        let (text, updated) = Self.splitMemory(answer)
        if let updated, ChatMemory.isEnabled { memory?.write(updated, for: conversation.chatId) }
        return text
    }

    /// The latest photos among these messages, at most `limit`, downloaded if needed, and the
    /// number each gets in the transcript ("[Photo 2]").
    private func photos(in messages: [MessageModel], limit: Int) async -> (urls: [URL], numbers: [Int64: Int]) {
        var urls: [URL] = []
        var numbers: [Int64: Int] = [:]
        for message in messages.filter({ if case .photo = $0.body { true } else { false } }).suffix(limit) {
            guard case .photo(let photo, _) = message.body, let url = await files.localFile(photo.image.fileId) else { continue }
            urls.append(url)
            numbers[message.id] = urls.count
        }
        return (urls, numbers)
    }

    // MARK: Catch Up

    /// Sums up the unread messages, or, with nothing unread, the latest stretch of the chat.
    public func catchUp() {
        guard summary != .working else { return }
        let (messages, unread) = Self.messagesToSummarize(conversation.messages, firstUnreadId: conversation.firstUnreadMessageId)
        guard !messages.isEmpty else {
            summary = .failed("There's nothing here to sum up yet.")
            return
        }
        summary = .working
        Task {
            // The photos you missed (or the latest ones), so Codex can say what they show.
            let photos = await photos(in: unread > 0 ? Array(messages.suffix(unread)) : messages, limit: 6)
            let prompt = Self.summaryPrompt(
                chatTitle: chatTitle, transcript: Self.transcript(messages, photoNumbers: photos.numbers),
                unreadCount: unread, photoCount: photos.urls.count, memory: currentMemory
            )
            do {
                summary = .done(keepingMemory(try await codex.ask(prompt, effort: .low, photos: photos.urls)))
            } catch {
                summary = .failed(error.localizedDescription)
            }
        }
    }

    public func dismissSummary() {
        summary = nil
    }

    /// Unread messages and a few before them for context; with fewer than three unread, the
    /// last day or so (at least 30 messages, at most 150).
    nonisolated static func messagesToSummarize(_ messages: [MessageModel], firstUnreadId: Int64?, now: Date = .now) -> (messages: [MessageModel], unreadCount: Int) {
        let readable = messages.filter { if case .service = $0.body { false } else { true } }
        if let firstUnreadId, let start = readable.firstIndex(where: { $0.id >= firstUnreadId }) {
            let unread = readable.count - start
            if unread >= 3 {
                return (Array(readable[max(0, start - 10)...].suffix(300)), unread)
            }
        }
        let dayAgo = now.addingTimeInterval(-26 * 3600)
        let recent = readable.filter { $0.date >= dayAgo }
        let chosen = recent.count >= 30 ? recent.suffix(150) : readable.suffix(30)
        return (Array(chosen), 0)
    }

    // MARK: Writing in the message box

    /// How much of the chat a draft sees: the conversation, and more of your own messages
    /// (however old) to learn how you write to this person.
    static let draftContext = 150
    static let draftStyleSamples = 60

    /// Writes your next message from the conversation; what's in the box is taken as a hint
    /// ("say I'm running late").
    public func draftReply() {
        let hint = conversation.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        write { [conversation, chatTitle] in
            let recent = Self.recentContext(await conversation.recentMessages(Self.draftContext + 20), count: Self.draftContext)
            let shown = Set(recent.map(\.id))
            let samples = await conversation.myRecentMessages(Self.draftStyleSamples)
                .filter { !shown.contains($0.id) }
                .map(\.plainText)
            // Photos from the last few messages: what you'd be replying to.
            let photos = await self.photos(in: Array(recent.suffix(12)), limit: 4)
            let prompt = Self.draftPrompt(
                chatTitle: chatTitle, transcript: Self.transcript(recent, photoNumbers: photos.numbers),
                styleSamples: samples, hint: hint.isEmpty ? nil : hint, photoCount: photos.urls.count,
                memory: self.currentMemory
            )
            return (prompt, photos.urls)
        }
    }

    public func polish(_ style: Polish) {
        let text = conversation.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let context = Self.transcript(Self.recentContext(conversation.messages, count: 8))
        write { (Self.polishPrompt(text, style: style, transcript: context), []) }
    }

    /// Puts back what you'd typed before Codex rewrote it.
    public func undoWriting() {
        guard let replacedText else { return }
        conversation.composerText = replacedText
        self.replacedText = nil
        writtenText = nil
        conversation.requestFocus()
    }

    /// Until you edit or send what Codex wrote.
    public var canUndoWriting: Bool {
        replacedText != nil && writtenText == conversation.composerText
    }

    private func write(_ request: @escaping @MainActor () async -> (prompt: String, photos: [URL])) {
        guard !isWriting else { return }
        isWriting = true
        let before = conversation.composerText
        Task {
            defer { isWriting = false }
            do {
                let (prompt, photos) = await request()
                let text = keepingMemory(try await codex.ask(prompt, effort: .low, photos: photos))
                // Typed something meanwhile: that wins.
                guard conversation.composerText == before else { return }
                replacedText = before
                writtenText = text
                conversation.composerText = text
                conversation.requestFocus()
            } catch {
                conversation.errorMessage = error.localizedDescription
            }
        }
    }

    nonisolated static func recentContext(_ messages: [MessageModel], count: Int = 30) -> [MessageModel] {
        Array(messages.filter { if case .service = $0.body { false } else { true } }.suffix(count))
    }

    // MARK: Translate

    /// Translates a message into the Mac's language, shown under it.
    public func translate(_ message: MessageModel) {
        guard let text = message.copyableText, translations[message.id] != .working else { return }
        translations[message.id] = .working
        let prompt = Self.translatePrompt(text, into: Self.languages.first?.englishName ?? "English")
        Task {
            do {
                translations[message.id] = .done(try await codex.ask(prompt, effort: .low))
            } catch {
                translations[message.id] = .failed(error.localizedDescription)
            }
        }
    }

    public func hideTranslation(_ messageId: Int64) {
        translations[messageId] = nil
    }

    /// The languages set up on this Mac, then English: what Translate offers.
    public static var languages: [Language] {
        var codes: [String] = []
        for identifier in Locale.preferredLanguages + ["en"] {
            if let code = Locale(identifier: identifier).language.languageCode?.identifier, !codes.contains(code) {
                codes.append(code)
            }
        }
        let english = Locale(identifier: "en")
        return codes.map { code in
            Language(
                code: code,
                name: Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code,
                englishName: english.localizedString(forLanguageCode: code) ?? code
            )
        }
    }

    // MARK: Prompts

    /// "[Mon 14:03] Emma: …" lines, oldest first. "Me" is you; photos shown to Codex are
    /// numbered ("[Photo 2: caption]").
    nonisolated static func transcript(_ messages: [MessageModel], photoNumbers: [Int64: Int] = [:]) -> String {
        let format = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "en_GB"))
        return messages.map { message in
            let name = message.isOutgoing ? "Me" : message.sender.name
            // Voice messages by their transcript; photos, files and stickers by what they are.
            var text = if let transcript = message.transcript {
                "[voice message] \(transcript)"
            } else if case .text = message.body {
                message.plainText
            } else if let number = photoNumbers[message.id] {
                message.plainText.isEmpty ? "[Photo \(number)]" : "[Photo \(number): \(message.plainText)]"
            } else {
                "[\(message.previewText)]"
            }
            if let reply = message.reply {
                text = "(replying to \(reply.senderName): \"\(reply.text.prefix(80))\") \(text)"
            }
            return "[\(message.date.formatted(format))] \(name): \(text.replacingOccurrences(of: "\n", with: " "))"
        }
        .joined(separator: "\n")
    }

    private nonisolated static let rules = """
    Answer with the text only: no introduction, no quotes around it, no markdown. Don't run \
    commands or open files; everything you need is below.
    """

    /// Says which attached picture is which.
    nonisolated static func photosNote(_ count: Int) -> String {
        switch count {
        case 0: ""
        case 1: "\nThe photo marked [Photo 1] is attached; look at it."
        default: "\nThe photos marked [Photo 1] to [Photo \(count)] are attached, in that order; look at them."
        }
    }

    nonisolated static let memoryMarker = "=== MEMORY ==="

    /// Asks Codex to append the chat's memory, updated, after its answer. Empty when memory is off.
    nonisolated static func memoryRequest(_ memory: String?, chatTitle: String) -> String {
        guard let memory else { return "" }
        return """


        After that, write a line with only "\(memoryMarker)", then the updated memory about this \
        chat: up to 8 short "- " points, at most 100 words, about what helps me write to \
        \(chatTitle): our language, how we address each other, tone, plans in progress, facts \
        worth remembering. Keep what's still true; drop what's outdated or trivial. Never include \
        passwords, codes, or card or account numbers.

        Current memory (also background for your answer):
        \(memory.isEmpty ? "(none yet)" : memory)
        """
    }

    /// Splits Codex's answer at the memory marker: the answer, and the new memory if any.
    nonisolated static func splitMemory(_ answer: String) -> (text: String, memory: String?) {
        let lines = answer.components(separatedBy: "\n")
        guard let index = lines.lastIndex(where: { $0.replacingOccurrences(of: " ", with: "").uppercased() == "===MEMORY===" }) else {
            return (answer, nil)
        }
        let text = lines[..<index].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let memory = lines[(index + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, memory)
    }

    nonisolated static func summaryPrompt(chatTitle: String, transcript: String, unreadCount: Int, photoCount: Int = 0, memory: String? = nil) -> String {
        let scope = unreadCount > 0
            ? "Me hasn't read the last \(unreadCount) messages (the few before them are for context)."
            : "These are the latest messages."
        return """
        Help me (shown as "Me") catch up on a Telegram chat with \(chatTitle). \(scope)
        Sum up what I need to know in at most five short points: what was said, plans, times and \
        places, what photos show if it matters, and anything waiting for my answer. Leave out \
        greetings and small talk. Write in the language most of the messages are in. Start each \
        point with "• ".\(photosNote(photoCount))
        \(rules)\(memoryRequest(memory, chatTitle: chatTitle))

        Messages:
        \(transcript)
        """
    }

    nonisolated static func draftPrompt(chatTitle: String, transcript: String, styleSamples: [String] = [], hint: String?, photoCount: Int = 0, memory: String? = nil) -> String {
        let what = hint.map { "What I want to say: \($0)\n" } ?? "Reply to what was said last, if anything needs a reply.\n"
        let samples = styleSamples
            .map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { "- \($0.prefix(300))" }
        let style = samples.isEmpty ? "" : """


        More of my earlier messages in this chat, only to show how I write to \(chatTitle):
        \(samples.joined(separator: "\n"))
        """
        return """
        Write my next message (I'm "Me") in this Telegram chat with \(chatTitle).
        \(what)Sound like me: match the language, length, punctuation, capitalisation and emoji \
        habits of my messages to this person. Keep it natural and short, like a real chat message.\(photosNote(photoCount))
        \(rules)\(memoryRequest(memory, chatTitle: chatTitle))

        Messages, oldest first:
        \(transcript)\(style)
        """
    }

    nonisolated static func polishPrompt(_ text: String, style: Polish, transcript: String) -> String {
        let task = switch style {
        case .fix: "Fix spelling, grammar and punctuation. Keep my wording, tone and language; change as little as possible."
        case .shorter: "Make it shorter and simpler, keeping the meaning, tone and language."
        case .friendlier: "Make it warmer and friendlier, keeping the meaning and language."
        case .formal: "Make it more formal and polite, keeping the meaning and language."
        case .translate(let language): "Translate it into \(language.englishName), keeping the tone."
        }
        return """
        Rewrite this message I'm about to send in a Telegram chat. \(task)
        \(rules)

        The chat so far, for context only:
        \(transcript)

        My message:
        \(text)
        """
    }

    nonisolated static func translatePrompt(_ text: String, into language: String) -> String {
        """
        Translate this Telegram message into \(language). Keep the tone, emoji and line breaks. \
        If it's already in \(language), give it back unchanged.
        \(rules)

        Message:
        \(text)
        """
    }
}
