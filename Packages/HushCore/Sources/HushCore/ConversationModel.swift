@preconcurrency import TDLibKit
import AppKit
import Foundation
import Observation

/// The open chat: its messages, the composer, and what you're doing to them.
@MainActor @Observable
public final class ConversationModel {
    public struct PendingDeletion: Equatable, Sendable {
        /// One message, or every item of an album.
        public let messages: [MessageModel]
        public let canDeleteForEveryone: Bool
        public let canDeleteForMe: Bool
    }

    public nonisolated let chatId: Int64
    public let isGroup: Bool
    public let isChannel: Bool
    /// Your own chat: Telegram lets you edit messages here at any age.
    let isSavedMessages: Bool
    /// False in channels where you aren't an admin: you can read and react, not post.
    public let canPost: Bool
    /// Telegram's sponsored message for this channel, shown below the last post.
    public internal(set) var sponsoredAd: SponsoredAd?
    /// Set while Telegram asks why you're reporting the ad.
    public var sponsoredReport: SponsoredReport?
    /// Oldest first. Changed only through `merge`, `remove` and `updateMessage`, which keep the
    /// timeline in step.
    public private(set) var messages: [MessageModel] = []
    /// The rows the conversation shows. Built when messages change rather than on every redraw,
    /// and then only from the first changed message on.
    public private(set) var timeline: [TimelineItem] = []
    public private(set) var hasOlderMessages = true
    public private(set) var isLoadingInitial = true
    /// The first message you hadn't read when the chat opened. The "Unread Messages" divider sits
    /// above it and stays put while you read.
    public private(set) var firstUnreadMessageId: Int64? {
        didSet {
            if firstUnreadMessageId != oldValue { rebuildTimeline() }
        }
    }
    /// Your messages up to this one have been read by the other side.
    public private(set) var lastReadOutboxMessageId: Int64
    /// "Alex is typing…", or nil.
    public private(set) var typingText: String?
    /// Who started typing (or recording, or choosing a sticker) first, of those still at it.
    public private(set) var typist: MessageModel.Sender?
    public var errorMessage: String?
    /// Why history didn't load. Shown with a way to try again.
    public private(set) var historyError: String?

    public var composerText: String
    /// Files waiting to go out with the next send.
    public private(set) var attachments: [Attachment] = []
    /// The file shown in Quick Look, if any. Photos and videos use Hushh's viewer instead.
    public var quickLookURL: URL?
    /// The photo or video open in the viewer.
    public private(set) var viewerMessageId: Int64?
    /// Which photos and videos the viewer steps through: the chat's loaded ones, or the shared
    /// media panel's.
    private var viewerShowsSharedMedia = false
    public private(set) var replyingTo: MessageModel?
    public private(set) var editing: MessageModel?
    public var pendingDeletion: PendingDeletion?
    /// Bumped whenever the composer should take keyboard focus.
    public private(set) var focusRequest = 0
    public let recorder = VoiceRecorder()
    public let voice: VoicePlayback

    @ObservationIgnored private let client: TDLibClient
    @ObservationIgnored private let chats: ChatStore
    /// The chat's photos, files, links, voice messages and music, for the details panel.
    @ObservationIgnored public private(set) lazy var sharedMedia = SharedMediaModel(chatId: chatId, client: client) { [weak self] in
        self?.model(for: $0)
    }
    @ObservationIgnored private var savedDraft: String
    @ObservationIgnored private var textBeforeEditing = ""
    /// While editing a message whose text can't go through Markdown and back unchanged (literal
    /// `__init__`, `**`, `||`, underlines): its original formatting, which saving carries over to
    /// the edited plain text. Nil when the composer shows the message as Markdown.
    @ObservationIgnored private var editingSource: FormattedText?
    /// The formatted text of your own messages, so editing keeps their formatting.
    @ObservationIgnored private var formattedTexts: [Int64: FormattedText] = [:]
    @ObservationIgnored private var oldestLoadedId: Int64?
    public private(set) var isLoadingOlder = false
    @ObservationIgnored private var replyCache: [Int64: ReplyPreview] = [:]
    @ObservationIgnored private var replyLookups: Set<Int64> = []
    /// Quoted messages TDLib couldn't be asked about (offline, say), with a reply that quotes each.
    @ObservationIgnored private var failedReplyLookups: [Int64: Int64] = [:]
    /// Who's typing and what they're doing ("typing", "recording a voice message"), in the
    /// order they started.
    @ObservationIgnored private var typing: [(senderId: Int64, sender: MessageSender, activity: String)] = []
    @ObservationIgnored private var visibleIds: Set<Int64> = []
    @ObservationIgnored private var viewedIds: Set<Int64> = []
    @ObservationIgnored private var isViewingScheduled = false
    @ObservationIgnored private var lastTypingSent = Foundation.Date.distantPast
    @ObservationIgnored private var isOpen = false
    @ObservationIgnored private(set) var isSponsoredAdViewed = false
    @ObservationIgnored private var isSponsoredAdFullyVisible = false
    /// Whether Hushh is the active app; replaced in tests.
    @ObservationIgnored var isAppActive: () -> Bool = { NSApp.isActive }

    init(chat: ChatItem, client: TDLibClient, chats: ChatStore, voice: VoicePlayback) {
        self.voice = voice
        chatId = chat.id
        isGroup = chat.kind == .group
        isChannel = chat.kind == .channel
        isSavedMessages = chat.kind == .savedMessages
        canPost = chats.canPost(in: chat)
        lastReadOutboxMessageId = chat.lastReadOutboxMessageId
        savedDraft = chat.rawDraft ?? ""
        composerText = savedDraft
        self.client = client
        self.chats = chats
    }

    // MARK: Opening and closing

    func open() async {
        isOpen = true
        focusRequest += 1
        let chatId = chatId
        let client = client
        _ = try? await client.openChat(chatId: chatId)

        let item = chats.item(chatId)
        let unreadCount = item?.unreadCount ?? 0
        let lastReadInboxMessageId = item?.lastReadInboxMessageId ?? 0
        // Enough history to cover everything unread, within reason.
        let target = min(max(unreadCount + 20, 50), 300)
        var loaded: [Message] = []
        var fromId: Int64 = 0
        while loaded.count < target, isOpen {
            let page: [Message]
            do {
                page = try await client.resilientChatHistory(
                    chatId: chatId, fromMessageId: fromId, limit: min(100, target - loaded.count)
                ).messages ?? []
            } catch {
                historyError = AuthModel.describe(error)
                break
            }
            // TDLib returns newest first and may repeat the message we started from.
            let older = page.filter { fromId == 0 || $0.id < fromId }
            guard let oldest = older.last else {
                hasOlderMessages = false
                break
            }
            loaded += older
            fromId = oldest.id
        }
        oldestLoadedId = loaded.last?.id
        merge(loaded)
        if unreadCount > 0 {
            firstUnreadMessageId = messages.first { !$0.isOutgoing && $0.id > lastReadInboxMessageId }?.id
        }
        isLoadingInitial = false
        if isChannel, let sponsored = try? await client.getChatSponsoredMessages(chatId: chatId) {
            sponsoredAd = sponsored.messages.lazy.compactMap(SponsoredAd.init).first
        }
    }

    /// Saves your draft and tells TDLib the chat is closed.
    func close() {
        guard isOpen else { return }
        isOpen = false
        recorder.cancel()
        // Nothing outside the chat can pause its voice message, so leaving the chat stops it.
        if voice.current?.chatId == chatId { voice.stop() }
        let draft = changedDraft()
        let chatId = chatId
        let client = client
        Task {
            if let draft {
                _ = try? await client.setChatDraftMessage(chatId: chatId, draftMessage: Self.draftMessage(draft), topicId: nil)
            }
            _ = try? await client.closeChat(chatId: chatId)
        }
    }

    /// Where older history continues: before the oldest message history loaded, or, when the
    /// first load failed, before the oldest message that arrived since (0: from the newest).
    private var historyStart: Int64 {
        oldestLoadedId ?? messages.first?.id ?? 0
    }

    /// When the app quits: hands TDLib the draft at once, so it has the request before it
    /// closes. `send` sends without waiting for an answer; there's no time for one.
    func closeBeforeQuitting(send: (SetChatDraftMessage) -> Void) {
        guard isOpen else { return }
        isOpen = false
        recorder.cancel()
        if let draft = changedDraft() {
            send(SetChatDraftMessage(chatId: chatId, draftMessage: Self.draftMessage(draft), topicId: nil))
        }
    }

    /// What's in the message box (what was there before an edit), if Telegram doesn't have it yet.
    private func changedDraft() -> String? {
        let draft = editing == nil ? composerText : textBeforeEditing
        return draft == savedDraft ? nil : draft
    }

    /// Loads the page of history before the oldest loaded message. Returns whether it found any.
    /// `afterMerge` runs in the same step that adds the page, so the view can adjust its scroll
    /// position before anything is drawn.
    @discardableResult
    public func loadOlder(limit: Int = 50, afterMerge: () -> Void = {}) async -> Bool {
        guard hasOlderMessages, !isLoadingOlder, !isLoadingInitial else { return false }
        let oldestId = historyStart
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        let page: [Message]
        do {
            page = try await client.resilientChatHistory(chatId: chatId, fromMessageId: oldestId, limit: limit).messages ?? []
        } catch {
            historyError = AuthModel.describe(error)
            return false
        }
        historyError = nil
        let older = page.filter { oldestId == 0 || $0.id < oldestId }
        guard let oldest = older.last else {
            hasOlderMessages = false
            return false
        }
        oldestLoadedId = oldest.id
        merge(older)
        afterMerge()
        return true
    }

    // MARK: Jumping to a message

    /// Asks the view to scroll to a message. A new one each time, so asking again scrolls again.
    public struct RevealRequest: Equatable, Sendable {
        public let messageId: Int64
        private let token = UUID()
    }

    public private(set) var revealRequest: RevealRequest?
    /// Set for a moment after a jump, so the message flashes.
    public private(set) var highlightedMessageId: Int64?

    /// How much history a jump loads, at most, before showing the message in context instead.
    static let revealLimit = 3_000

    /// Scrolls to a message (a search result, say), loading older history until it's there.
    /// False when it's further back than `revealLimit` messages, or gone.
    @discardableResult
    public func reveal(_ messageId: Int64) async -> Bool {
        if !messages.contains(where: { $0.id == messageId }) {
            guard await loadHistory(through: messageId) else { return false }
        }
        revealRequest = RevealRequest(messageId: messageId)
        highlightedMessageId = messageId
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if highlightedMessageId == messageId { highlightedMessageId = nil }
        }
        return true
    }

    /// Loads older history until it includes the message, plus a page more so the message isn't
    /// right at the top (where scrolling would load more and move it). The pages are gathered
    /// first and merged once: a merge per page would redraw the conversation every time.
    private func loadHistory(through messageId: Int64) async -> Bool {
        while isLoadingOlder || isLoadingInitial {
            try? await Task.sleep(for: .milliseconds(50))
        }
        var from = historyStart
        guard hasOlderMessages, from == 0 || messageId < from else { return false }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        var gathered: [Message] = []
        var isFound = false
        while messages.count + gathered.count < Self.revealLimit {
            guard let page = try? await client.resilientChatHistory(chatId: chatId, fromMessageId: from, limit: 100).messages else {
                return false
            }
            let older = page.filter { from == 0 || $0.id < from }
            guard let oldest = older.last else {
                hasOlderMessages = false
                break
            }
            gathered += older
            from = oldest.id
            if isFound { break }
            isFound = older.contains { $0.id == messageId }
        }
        guard isFound else { return false }
        oldestLoadedId = from
        merge(gathered)
        return true
    }

    /// Hides the history error without trying again.
    public func dismissHistoryError() {
        historyError = nil
    }

    /// A message with a few on either side, oldest first: for one too far back to jump to.
    public func context(around messageId: Int64) async -> [MessageModel] {
        let page = try? await client.resilientChatHistory(chatId: chatId, fromMessageId: messageId, limit: 9, offset: -4)
        return (page?.messages ?? []).compactMap(model(for:)).reversed()
    }

    // MARK: Searching

    /// History before `messageId` (0: from the newest), newest first: for the search index.
    public func historyPage(before messageId: Int64, limit: Int = 100) async throws -> [MessageModel] {
        let page = try await client.resilientChatHistory(chatId: chatId, fromMessageId: messageId, limit: limit)
        return (page.messages ?? []).filter { messageId == 0 || $0.id < messageId }.compactMap(model(for:))
    }

    /// Messages containing the words, across the chat's whole history: Telegram's own search.
    public func searchMessages(_ query: String, limit: Int = 50) async throws -> [MessageModel] {
        let found = try await client.resilientSearchChatMessages(chatId: chatId, query: query, filter: nil, fromMessageId: 0, limit: limit)
        return found.messages.compactMap(model(for:))
    }

    /// Messages by id, in the order asked: from what's loaded, otherwise from TDLib. Those TDLib
    /// says don't exist (deleted since) are in `gone`; those it couldn't fetch (offline, a flood
    /// wait) are only left out.
    public func messages(withIds ids: [Int64]) async -> (found: [MessageModel], gone: Set<Int64>) {
        let loaded = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var found: [MessageModel] = []
        var gone: Set<Int64> = []
        for id in ids {
            if let message = loaded[id] {
                found.append(message)
                continue
            }
            do {
                if let model = model(for: try await client.resilientMessage(chatId: chatId, messageId: id)) {
                    found.append(model)
                }
            } catch let error as TDLibKit.Error where error.code == 404 {
                gone.insert(id)
            } catch {}
        }
        return (found, gone)
    }

    /// The Mac's time zone changed: days and time headings fall elsewhere.
    public func calendarChanged() {
        NSTimeZone.resetSystemTimeZone()
        rebuildTimeline()
    }

    private func rebuildTimeline() {
        timeline = Timeline.build(messages, firstUnreadMessageId: firstUnreadMessageId)
    }

    // MARK: Composer

    public var canSend: Bool {
        !attachments.isEmpty || !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Telegram's longest text message, the same with or without Premium. Longer text goes out
    /// as several messages, as in Telegram's own apps.
    static let maxMessageLength = 4096

    public func send() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        if editing == nil, !attachments.isEmpty {
            sendAttachments(caption: text)
            return
        }
        guard !text.isEmpty else { return }
        if let editing {
            saveEdit(of: editing, text: text)
            return
        }
        let reply = replyingTo
        let draft = savedDraft
        // Clear right away; TDLib shows the new message as sending within milliseconds. If TDLib
        // turns it down, everything comes back.
        composerText = ""
        replyingTo = nil
        savedDraft = ""  // sending clears the draft
        lastTypingSent = .distantPast
        let chatId = chatId
        let client = client
        Task {
            var sent = 0
            do {
                // **bold**, __italic__, ~~strikethrough~~, ||spoiler||, `code` and [links](https://…).
                let formatted = try await client.parseMarkdown(text: FormattedText(entities: [], text: text))
                var replyTo = Self.replyTo(reply?.id)
                for part in Self.split(formatted, limit: Self.maxMessageLength) {
                    let content = InputMessageContent.inputMessageText(InputMessageText(clearDraft: true, linkPreviewOptions: nil, text: part))
                    _ = try await client.sendMessage(chatId: chatId, inputMessageContent: content, options: nil, replyMarkup: nil, replyTo: replyTo, topicId: nil)
                    replyTo = nil
                    sent += 1
                }
            } catch {
                errorMessage = Self.describeSendError(error)
                // Only when nothing went out: a long text that failed half way would be sent twice.
                if sent == 0 {
                    savedDraft = draft
                    restore(text: text, replyingTo: reply)
                }
            }
        }
    }

    /// Saves an edit. The composer goes back to what it held before; if Telegram refuses the
    /// edit (too old, deleted, offline), the edit comes back with your new text.
    private func saveEdit(of message: MessageModel, text: String) {
        let source = editingSource
        editing = nil
        editingSource = nil
        composerText = textBeforeEditing
        let chatId = chatId
        let client = client
        Task {
            do {
                let formatted = if let source {
                    Self.carryFormatting(of: source, over: text)
                } else {
                    try await client.parseMarkdown(text: FormattedText(entities: [], text: text))
                }
                let content = InputMessageContent.inputMessageText(InputMessageText(clearDraft: false, linkPreviewOptions: nil, text: formatted))
                _ = try await client.editMessageText(chatId: chatId, inputMessageContent: content, messageId: message.id, replyMarkup: nil)
            } catch {
                errorMessage = Self.describeSendError(error)
                if editing == nil, replyingTo == nil, attachments.isEmpty,
                   let current = messages.first(where: { $0.id == message.id }) {
                    textBeforeEditing = composerText
                    editing = current
                    editingSource = source
                    composerText = text
                    focusRequest += 1
                } else {
                    restore(text: text, replyingTo: nil)
                }
            }
        }
    }

    /// Puts back what a failed send took out of the message box, without overwriting anything
    /// you've typed since: your text goes before it.
    private func restore(text: String, replyingTo reply: MessageModel?, attachments items: [Attachment] = []) {
        func joined(_ restored: String, _ current: String) -> String {
            current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? restored : restored + "\n" + current
        }
        if !text.isEmpty {
            if editing != nil {
                textBeforeEditing = joined(text, textBeforeEditing)
            } else {
                composerText = joined(text, composerText)
            }
        }
        if editing == nil, replyingTo == nil, let reply, messages.contains(where: { $0.id == reply.id }) {
            replyingTo = reply
        }
        attachments = items + attachments
        focusRequest += 1
    }

    /// TDLib's answer in words, for the errors a send or an edit commonly meets.
    /// Nil for errors TDLib says must not be shown (code 406); the text stays in the box.
    static func describeSendError(_ error: any Swift.Error) -> String? {
        switch (error as? TDLibKit.Error)?.message {
        case "MESSAGE_EDIT_TIME_EXPIRED":
            "This message is too old to edit."
        case "MESSAGE_NOT_MODIFIED":
            "Nothing changed in the message."
        case "Message is too long", "MESSAGE_TOO_LONG":
            "The message is longer than Telegram allows."
        case "Message caption is too long", "MEDIA_CAPTION_TOO_LONG":
            "The caption is longer than Telegram allows (1,024 characters without Premium). Shorten it, or send the text as a separate message."
        default:
            AuthModel.describe(error)
        }
    }

    /// Splits formatted text into pieces of at most `limit` UTF-16 units, at a line break or a
    /// space where possible, keeping each piece's formatting.
    nonisolated static func split(_ text: FormattedText, limit: Int) -> [FormattedText] {
        let units = Array(text.text.utf16)
        guard units.count > limit else { return [text] }
        var pieces: [FormattedText] = []
        var start = 0
        while start < units.count {
            var end = min(start + limit, units.count)
            if end < units.count {
                let window = units[start ..< end]
                if let newline = window.lastIndex(of: 0x0A), newline > start {
                    end = newline + 1
                } else if let space = window.lastIndex(of: 0x20), space > start {
                    end = space + 1
                } else if UTF16.isTrailSurrogate(units[end]) {
                    end -= 1  // never cut an emoji in half
                }
            }
            let entities = text.entities.compactMap { entity -> TextEntity? in
                let from = max(entity.offset, start)
                let to = min(entity.offset + entity.length, end)
                guard from < to else { return nil }
                return TextEntity(length: to - from, offset: from - start, type: entity.type)
            }
            let piece = String(decoding: units[start ..< end], as: UTF16.self)
            if !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pieces.append(FormattedText(entities: entities, text: piece))
            }
            start = end
        }
        return pieces
    }

    /// The formatting of `source` moved onto `text`, an edit of its plain text: formatting
    /// before and after the changed part stays where it was, formatting around the change
    /// stretches over it. No Markdown is read, so `*`, `_`, `|` and `~` stay as typed.
    nonisolated static func carryFormatting(of source: FormattedText, over text: String) -> FormattedText {
        let old = Array(source.text.unicodeScalars)
        let new = Array(text.unicodeScalars)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        func utf16Length(_ scalars: ArraySlice<Unicode.Scalar>) -> Int { scalars.reduce(0) { $0 + UTF16.width($1) } }
        let changeStart = utf16Length(old[..<prefix])
        let oldChangeEnd = utf16Length(old[..<(old.count - suffix)])
        let newChangeEnd = utf16Length(new[..<(new.count - suffix)])
        let delta = newChangeEnd - oldChangeEnd

        let entities = source.entities.compactMap { entity -> TextEntity? in
            let start = entity.offset
            let end = entity.offset + entity.length
            if end <= changeStart { return entity }
            // Text typed right before formatted text doesn't take its formatting.
            if start >= oldChangeEnd {
                return TextEntity(length: entity.length, offset: start + delta, type: entity.type)
            }
            // A custom emoji must cover exactly its emoji; one touched by the edit is dropped.
            if case .textEntityTypeCustomEmoji = entity.type { return nil }
            let newStart = start <= changeStart ? start : changeStart
            let newEnd = end >= oldChangeEnd ? end + delta : newChangeEnd
            guard newEnd > newStart else { return nil }
            return TextEntity(length: newEnd - newStart, offset: newStart, type: entity.type)
        }
        return FormattedText(entities: entities, text: text)
    }

    // MARK: Attachments, stickers and GIFs

    /// Adds files to send (from the attach button, drag and drop, or paste). `asFiles` sends
    /// pictures and videos as files, in original quality, rather than compressed. Folders are
    /// refused: Telegram can only send files.
    public func attach(_ urls: [URL], asFiles: Bool = false) {
        let isFolder = { (url: URL) in
            url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        let candidates = urls.filter(\.isFileURL)
        let files = candidates.filter { !isFolder($0) }
        if files.count < candidates.count {
            errorMessage = "Folders can't be sent. Compress a folder into a .zip file first."
        }
        guard !files.isEmpty else { return }
        cancelEditing()
        for url in files {
            // The sandbox lets Hush read files you picked or dropped. Keep that access for the
            // rest of the session, since TDLib uploads in the background.
            _ = url.startAccessingSecurityScopedResource()
            attachments.append(Attachment(url: url, asFile: asFiles))
        }
        focusRequest += 1
    }

    public func removeAttachment(_ attachment: Attachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    public func sendSticker(_ sticker: StickerMedia) {
        let reply = replyingTo
        replyingTo = nil
        let chatId = chatId
        let client = client
        Task {
            do {
                try await Self.sendSticker(sticker, replyToMessageId: reply?.id, chatId: chatId, client: client)
            } catch {
                errorMessage = Self.describeSendError(error)
                restore(text: "", replyingTo: reply)
            }
        }
    }

    public func sendGIF(_ gif: VideoMedia) {
        let reply = replyingTo
        replyingTo = nil
        let chatId = chatId
        let client = client
        Task {
            do {
                try await Self.sendGIF(gif, replyToMessageId: reply?.id, chatId: chatId, client: client)
            } catch {
                errorMessage = Self.describeSendError(error)
                restore(text: "", replyingTo: reply)
            }
        }
    }

    /// Photos and videos go out together as albums (up to 10 per album, Telegram's limit);
    /// files, and anything Hushh couldn't read as a photo or video, follow one by one. The
    /// caption goes on the first item. If something fails, what hasn't gone out comes back to
    /// the composer, with the caption and reply when nothing went out at all.
    private func sendAttachments(caption: String) {
        let items = attachments
        let reply = replyingTo
        let draft = savedDraft
        attachments = []
        composerText = ""
        replyingTo = nil
        savedDraft = ""
        let chatId = chatId
        let client = client
        Task {
            var unsent = items
            do {
                let formattedCaption = caption.isEmpty ? nil : try await client.parseMarkdown(text: FormattedText(entities: [], text: caption))
                var replyTo = Self.replyTo(reply?.id)
                for batch in await Self.batches(items, caption: formattedCaption) {
                    if batch.contents.count == 1 {
                        _ = try await client.sendMessage(chatId: chatId, inputMessageContent: batch.contents[0], options: nil, replyMarkup: nil, replyTo: replyTo, topicId: nil)
                    } else {
                        _ = try await client.sendMessageAlbum(chatId: chatId, inputMessageContents: batch.contents, options: nil, replyTo: replyTo, topicId: nil)
                    }
                    replyTo = nil
                    unsent.removeAll { batch.ids.contains($0.id) }
                }
                // Only text messages clear the draft by themselves.
                if !draft.isEmpty {
                    _ = try? await client.setChatDraftMessage(chatId: chatId, draftMessage: nil, topicId: nil)
                }
            } catch {
                errorMessage = Self.describeSendError(error)
                let nothingSent = unsent.count == items.count
                if nothingSent { savedDraft = draft }
                restore(text: nothingSent ? caption : "", replyingTo: nothingSent ? reply : nil, attachments: unsent)
            }
        }
    }

    /// What one sendMessage or sendMessageAlbum call sends.
    struct AttachmentBatch: Sendable {
        let ids: [UUID]
        let contents: [InputMessageContent]
    }

    /// Prepares the attachments, then groups them by what they turned into: Telegram only puts
    /// photos and videos together in an album, so a picture Hushh couldn't read (sent as a
    /// file instead) mustn't land in one.
    nonisolated static func batches(_ items: [Attachment], caption: FormattedText?) async -> [AttachmentBatch] {
        var media: [(id: UUID, content: InputMessageContent)] = []
        var documents: [(id: UUID, content: InputMessageContent)] = []
        for item in items {
            let content = await AttachmentPreparer.content(for: item, caption: nil)
            if case .inputMessageDocument = content {
                documents.append((item.id, content))
            } else {
                media.append((item.id, content))
            }
        }
        if let caption {
            if !media.isEmpty {
                media[0].content = AttachmentPreparer.captioned(media[0].content, caption)
            } else if !documents.isEmpty {
                documents[0].content = AttachmentPreparer.captioned(documents[0].content, caption)
            }
        }
        var batches = stride(from: 0, to: media.count, by: 10).map { start in
            let album = media[start ..< min(start + 10, media.count)]
            return AttachmentBatch(ids: album.map(\.id), contents: album.map(\.content))
        }
        batches += documents.map { AttachmentBatch(ids: [$0.id], contents: [$0.content]) }
        return batches
    }

    private nonisolated static func sendSticker(
        _ sticker: StickerMedia, replyToMessageId: Int64?, chatId: Int64, client: TDLibClient
    ) async throws {
        let content = InputMessageContent.inputMessageSticker(InputMessageSticker(
            emoji: sticker.emoji,
            sticker: InputSticker(height: sticker.height, sticker: .inputFileId(InputFileId(id: sticker.fileId)), thumbnail: nil, width: sticker.width)
        ))
        _ = try await client.sendMessage(chatId: chatId, inputMessageContent: content, options: nil, replyMarkup: nil, replyTo: replyTo(replyToMessageId), topicId: nil)
    }

    private nonisolated static func sendGIF(
        _ gif: VideoMedia, replyToMessageId: Int64?, chatId: Int64, client: TDLibClient
    ) async throws {
        let content = InputMessageContent.inputMessageAnimation(InputMessageAnimation(
            animation: InputAnimation(
                addedStickerFileIds: [], animation: .inputFileId(InputFileId(id: gif.fileId)),
                duration: gif.duration, height: gif.height, thumbnail: nil, width: gif.width
            ),
            caption: nil,
            hasSpoiler: false,
            showCaptionAboveMedia: false
        ))
        _ = try await client.sendMessage(chatId: chatId, inputMessageContent: content, options: nil, replyMarkup: nil, replyTo: replyTo(replyToMessageId), topicId: nil)
    }

    // MARK: Viewer

    public var viewerMessage: MessageModel? {
        viewerMessageId.flatMap { id in viewableMedia.first { $0.id == id } ?? messages.first { $0.id == id } }
    }

    /// The photos and videos to step through in the viewer, oldest first: the chat's loaded
    /// ones, or the shared media panel's when opened from there.
    public var viewableMedia: [MessageModel] {
        viewerShowsSharedMedia ? sharedMedia.items(.media).reversed() : messages.filter(\.isViewableMedia)
    }

    public func openViewer(_ message: MessageModel, fromSharedMedia: Bool = false) {
        viewerShowsSharedMedia = fromSharedMedia
        viewerMessageId = message.id
    }

    /// Puts the keyboard back in the message box.
    public func requestFocus() {
        focusRequest += 1
    }

    public func closeViewer() {
        viewerMessageId = nil
        focusRequest += 1  // back to the message box
    }

    /// The previous (−1) or next (+1) photo or video, if there is one.
    public func showAdjacentMedia(_ step: Int) {
        let media = viewableMedia
        guard let index = media.firstIndex(where: { $0.id == viewerMessageId }), media.indices.contains(index + step) else { return }
        viewerMessageId = media[index + step].id
        // Stepping back through the panel's media: fetch older ones before running out.
        if viewerShowsSharedMedia, index + step < 5 {
            Task { await sharedMedia.loadMore(.media) }
        }
    }

    // MARK: Transcription

    /// Voice messages and circles you've asked Telegram to transcribe, until its answer arrives.
    public private(set) var requestedTranscriptions: Set<Int64> = []
    /// Why Telegram turned a transcription down straight away (no Premium, say).
    public private(set) var transcriptionErrors: [Int64: String] = [:]

    /// Asks Telegram to transcribe a voice message or circle, as its apps do. The text arrives
    /// with the message's next updates, partly at first, as Telegram works through it.
    public func transcribe(_ message: MessageModel) {
        let id = message.id
        requestedTranscriptions.insert(id)
        transcriptionErrors[id] = nil
        let chatId = chatId
        let client = client
        Task {
            do {
                _ = try await client.recognizeSpeech(chatId: chatId, messageId: id)
            } catch {
                requestedTranscriptions.remove(id)
                transcriptionErrors[id] = Transcription.describe((error as? TDLibKit.Error)?.message ?? "\(error)")
            }
        }
    }

    // MARK: Voice messages

    /// Plays or pauses a voice message. Playing someone's for the first time marks it as listened,
    /// which they see, as in Telegram's own apps.
    public func playVoiceNote(_ message: MessageModel, url: URL) {
        let startedFromBeginning = voice.toggle(VoicePlayback.Key(chatId: chatId, messageId: message.id), url: url)
        guard startedFromBeginning, !message.isOutgoing,
              case .voiceNote(let note, _) = message.body, !note.isListened else { return }
        let chatId = chatId
        let client = client
        Task { _ = try? await client.openMessageContent(chatId: chatId, messageId: message.id) }
    }

    public func startRecording() {
        guard recorder.state == .idle else { return }
        cancelEditing()
        Task {
            do {
                try await recorder.start()
                if recorder.state == .recording { sendRecordingAction() }
            } catch let denied as VoiceRecorder.MicrophoneDenied {
                errorMessage = denied.description
            } catch let allowed as VoiceRecorder.MicrophoneAllowed {
                errorMessage = allowed.description
            } catch {
                errorMessage = "Hushh couldn't start recording."
                Log.session.error("Can't record: \(String(describing: error), privacy: .public)")
            }
        }
    }

    public func cancelRecording() {
        recorder.cancel()
    }

    /// ⌘R: start recording, or send what's been recorded.
    public func toggleRecording() {
        switch recorder.state {
        case .idle: startRecording()
        case .recording: finishRecording()
        case .waitingForPermission, .encoding: break
        }
    }

    public func finishRecording() {
        guard recorder.state == .recording else { return }
        let reply = replyingTo
        replyingTo = nil
        let chatId = chatId
        let client = client
        Task {
            let note: VoiceNoteEncoder.VoiceNote?
            do {
                note = try await recorder.finish()
            } catch {
                Log.session.error("Can't encode voice message: \(String(describing: error), privacy: .public)")
                errorMessage = "Hushh couldn't make a voice message from the recording. Check that the microphone works."
                restore(text: "", replyingTo: reply)
                return
            }
            guard let note else {
                restore(text: "", replyingTo: reply)  // too short to send
                return
            }
            do {
                try await Self.sendVoiceNote(note, replyToMessageId: reply?.id, chatId: chatId, client: client)
            } catch {
                errorMessage = Self.describeSendError(error)
                restore(text: "", replyingTo: reply)
            }
        }
    }

    /// Shows "recording a voice message…" to the chat while you record, refreshed like typing.
    private func sendRecordingAction() {
        let chatId = chatId
        let client = client
        Task { [weak self] in
            while let self, self.recorder.state == .recording {
                _ = try? await client.sendChatAction(action: .chatActionRecordingVoiceNote, businessConnectionId: nil, chatId: chatId, topicId: nil)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private nonisolated static func sendVoiceNote(
        _ note: VoiceNoteEncoder.VoiceNote, replyToMessageId: Int64?, chatId: Int64, client: TDLibClient
    ) async throws {
        let content = InputMessageContent.inputMessageVoiceNote(InputMessageVoiceNote(
            caption: nil,
            selfDestructType: nil,
            voiceNote: InputVoiceNote(duration: note.duration, voiceNote: .inputFileLocal(InputFileLocal(path: note.url.path)), waveform: note.waveform)
        ))
        _ = try await client.sendMessage(chatId: chatId, inputMessageContent: content, options: nil, replyMarkup: nil, replyTo: replyTo(replyToMessageId), topicId: nil)
    }

    // MARK: Sponsored messages

    /// The ad's whole text came into view, or left it. Telegram counts the view once the whole
    /// text is on screen; while Hushh isn't the active app, that waits until it is.
    public func sponsoredAdVisibilityChanged(isFullyVisible: Bool) {
        isSponsoredAdFullyVisible = isFullyVisible
        viewSponsoredAdIfShown()
    }

    private func viewSponsoredAdIfShown() {
        guard let ad = sponsoredAd, isSponsoredAdFullyVisible, !isSponsoredAdViewed, isAppActive() else { return }
        isSponsoredAdViewed = true
        let chatId = chatId
        let client = client
        Task { _ = try? await client.viewMessages(chatId: chatId, forceRead: false, messageIds: [ad.id], source: nil) }
    }

    /// Tells Telegram the ad was clicked. The view then opens its link.
    public func sponsoredAdClicked(isMediaClick: Bool) {
        guard let ad = sponsoredAd else { return }
        let chatId = chatId
        let client = client
        Task {
            _ = try? await client.clickChatSponsoredMessage(chatId: chatId, fromFullscreen: false, isMediaClick: isMediaClick, messageId: ad.id)
        }
    }

    /// Reports the ad. Telegram answers with reasons to choose from; pass the chosen one back.
    public func reportSponsoredAd(option: SponsoredReport.Option? = nil) {
        guard let ad = sponsoredAd else { return }
        sponsoredReport = nil
        let chatId = chatId
        let client = client
        Task {
            do {
                let result = try await client.reportChatSponsoredMessage(chatId: chatId, messageId: ad.id, optionId: option?.id ?? Data())
                switch result {
                case .reportSponsoredResultOptionRequired(let choice):
                    sponsoredReport = SponsoredReport(
                        title: choice.title,
                        options: choice.options.map { SponsoredReport.Option(id: $0.id, text: $0.text) }
                    )
                case .reportSponsoredResultOk, .reportSponsoredResultAdsHidden:
                    sponsoredAd = nil
                case .reportSponsoredResultPremiumRequired:
                    errorMessage = "Hiding ads needs Telegram Premium."
                case .reportSponsoredResultFailed:
                    errorMessage = "Telegram couldn't take the report. Try again later."
                }
            } catch let error as TDLibKit.Error where error.message == "AD_EXPIRED" {
                sponsoredAd = nil
            } catch {
                errorMessage = AuthModel.describe(error)
            }
        }
    }

    // MARK: Reactions

    /// The emoji this chat allows as reactions.
    public var reactionChoices: [String] {
        chats.reactionChoices(for: chatId)
    }

    /// Adds your reaction, or takes it back if you'd already chosen it.
    public func toggleReaction(_ emoji: String, on message: MessageModel) {
        let isChosen = message.reactions.contains { $0.kind == .emoji(emoji) && $0.isChosen }
        let chatId = chatId
        let client = client
        Task {
            do {
                try await Self.setReaction(emoji, chosen: !isChosen, messageId: message.id, chatId: chatId, client: client)
            } catch {
                errorMessage = AuthModel.describe(error)
            }
        }
    }

    private nonisolated static func setReaction(_ emoji: String, chosen: Bool, messageId: Int64, chatId: Int64, client: TDLibClient) async throws {
        let reaction = ReactionType.reactionTypeEmoji(ReactionTypeEmoji(emoji: emoji))
        if chosen {
            _ = try await client.addMessageReaction(chatId: chatId, isBig: false, messageId: messageId, reactionType: reaction, updateRecentReactions: true)
        } else {
            _ = try await client.removeMessageReaction(chatId: chatId, messageId: messageId, reactionType: reaction)
        }
    }

    /// Tells the chat you're typing, at most every few seconds, like Telegram's own apps.
    public func composerChanged() {
        guard !composerText.isEmpty, editing == nil,
              Foundation.Date.now.timeIntervalSince(lastTypingSent) > 5 else { return }
        lastTypingSent = .now
        let chatId = chatId
        let client = client
        Task { _ = try? await client.sendChatAction(action: .chatActionTyping, businessConnectionId: nil, chatId: chatId, topicId: nil) }
    }

    public func reply(to message: MessageModel) {
        guard canPost else { return }  // no composer to reply in
        cancelEditing()
        replyingTo = message
        focusRequest += 1
    }

    public func cancelReply() {
        replyingTo = nil
    }

    /// How long Telegram lets you edit a message, outside Saved Messages and channels.
    static let editTimeLimit: TimeInterval = 48 * 3600

    /// Whether to offer Edit: your own text that Telegram still lets you change. Telegram has
    /// the last word when editing starts (`getMessageProperties`).
    public func canEdit(_ message: MessageModel) -> Bool {
        guard message.canEditText, formattedTexts[message.id] != nil else { return false }
        return isSavedMessages || isChannel || Foundation.Date.now.timeIntervalSince(message.date) < Self.editTimeLimit
    }

    public func startEditing(_ message: MessageModel) {
        guard canEdit(message), let formatted = formattedTexts[message.id] else { return }
        replyingTo = nil
        if editing == nil { textBeforeEditing = composerText }
        editing = message
        // Plain text, keeping the formatting aside, until it's clear Markdown can show it.
        editingSource = formatted
        composerText = formatted.text
        focusRequest += 1
        let chatId = chatId
        let client = client
        Task {
            if let properties = try? await client.getMessageProperties(chatId: chatId, messageId: message.id),
               !properties.canBeEdited, editing?.id == message.id {
                cancelEditing()
                errorMessage = "Telegram doesn't allow editing this message anymore."
                return
            }
            // Show the formatting as Markdown, but only when reading that Markdown back gives the
            // same message, and you haven't started typing.
            guard editing?.id == message.id, composerText == formatted.text,
                  let markdown = try? await client.getMarkdownText(text: formatted),
                  let reparsed = try? await client.parseMarkdown(text: FormattedText(entities: [], text: markdown.text)),
                  Self.sameFormatting(reparsed, formatted),
                  editing?.id == message.id, composerText == formatted.text
            else { return }
            editingSource = nil
            composerText = markdown.text
        }
    }

    /// Whether two texts read the same and carry the same formatting you can type (links,
    /// mentions and hashtags Telegram finds by itself don't count).
    nonisolated static func sameFormatting(_ a: FormattedText, _ b: FormattedText) -> Bool {
        func typed(_ text: FormattedText) -> [String] {
            text.entities.filter { entity in
                switch entity.type {
                case .textEntityTypeUrl, .textEntityTypeMention, .textEntityTypeHashtag, .textEntityTypeCashtag,
                     .textEntityTypeBotCommand, .textEntityTypeEmailAddress, .textEntityTypePhoneNumber,
                     .textEntityTypeBankCardNumber: false
                default: true
                }
            }
            .map { "\($0.offset) \($0.length) \($0.type)" }
            .sorted()
        }
        return a.text == b.text && typed(a) == typed(b)
    }

    public func cancelEditing() {
        guard editing != nil else { return }
        editing = nil
        editingSource = nil
        composerText = textBeforeEditing
    }

    /// ↑ in an empty composer edits your last message, as in Telegram and Signal. False (the
    /// key moves the caret as usual) when there's nothing to edit.
    public func editLastMessage() -> Bool {
        guard composerText.isEmpty, editing == nil, attachments.isEmpty, recorder.state == .idle,
              let message = messages.last(where: canEdit) else { return false }
        startEditing(message)
        return editing != nil
    }

    /// Esc in the message box: stops waiting for the microphone or drops the recording, then an
    /// edit, a reply or attachments, in that order. False when there was nothing to drop.
    public func cancelComposerMode() -> Bool {
        if recorder.state == .waitingForPermission || recorder.state == .recording {
            cancelRecording()
            return true
        }
        if editing != nil {
            cancelEditing()
            return true
        }
        if replyingTo != nil {
            replyingTo = nil
            return true
        }
        if !attachments.isEmpty {
            attachments.removeAll()
            return true
        }
        return false
    }

    /// Sends a message that failed again ("Try Again"). Telegram says when that's possible.
    public func resend(_ message: MessageModel) {
        let chatId = chatId
        let client = client
        Task {
            do {
                _ = try await client.resendMessages(chatId: chatId, messageIds: [message.id], paidMessageStarCount: 0, quote: nil)
            } catch {
                errorMessage = Self.describeSendError(error)
            }
        }
    }

    // MARK: Deleting

    public func requestDeletion(of messages: [MessageModel]) {
        guard let message = messages.first else { return }
        let chatId = chatId
        let client = client
        Task {
            let properties: MessageProperties
            do {
                properties = try await client.getMessageProperties(chatId: chatId, messageId: message.id)
            } catch {
                // Without TDLib's answer there's no telling which deletions it would accept.
                errorMessage = AuthModel.describe(error)
                return
            }
            let canDeleteForEveryone = properties.canBeDeletedForAllUsers
            let canDeleteForMe = properties.canBeDeletedOnlyForSelf
            guard canDeleteForEveryone || canDeleteForMe else {
                errorMessage = "You can't delete this message."
                return
            }
            pendingDeletion = PendingDeletion(messages: messages, canDeleteForEveryone: canDeleteForEveryone, canDeleteForMe: canDeleteForMe)
        }
    }

    public func delete(_ deletion: PendingDeletion, forEveryone: Bool) {
        pendingDeletion = nil
        let chatId = chatId
        let client = client
        Task {
            do {
                _ = try await client.deleteMessages(chatId: chatId, messageIds: deletion.messages.map(\.id), revoke: forEveryone)
            } catch {
                errorMessage = AuthModel.describe(error)
            }
        }
    }

    // MARK: Reading

    /// The timeline reports which messages are actually on screen; only those get marked as read.
    public func messageAppeared(_ id: Int64) {
        visibleIds.insert(id)
        scheduleViewing()
    }

    public func messageDisappeared(_ id: Int64) {
        visibleIds.remove(id)
    }

    func appBecameActive() {
        scheduleViewing()
        viewSponsoredAdIfShown()
    }

    private func scheduleViewing() {
        guard !isViewingScheduled else { return }
        isViewingScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.viewVisibleMessages()
        }
    }

    private func viewVisibleMessages() {
        isViewingScheduled = false
        // Messages count as read only while you're actually looking at Hush.
        guard isOpen, NSApp.isActive else { return }
        let ids = visibleIds.subtracting(viewedIds)
        guard !ids.isEmpty else { return }
        viewedIds.formUnion(ids)
        let chatId = chatId
        let client = client
        Task {
            _ = try? await client.viewMessages(chatId: chatId, forceRead: false, messageIds: ids.sorted(), source: .messageSourceChatHistory)
        }
    }

    // MARK: Updates

    func handle(_ update: Update) {
        switch update {
        case .updateNewMessage(let update) where update.message.chatId == chatId:
            merge([update.message])
        case .updateMessageSendSucceeded(let update) where update.message.chatId == chatId:
            replace(update.oldMessageId, with: update.message)
        case .updateMessageSendFailed(let update) where update.message.chatId == chatId:
            replace(update.oldMessageId, with: update.message)
        case .updateChatDraftMessage(let update) where update.chatId == chatId:
            // A draft from another device, taken only if you haven't typed here since.
            let draft = MessagePreview.rawDraftText(update.draftMessage) ?? ""
            guard editing == nil, composerText == savedDraft else { return }
            savedDraft = draft
            composerText = draft
        case .updateMessageContent(let update) where update.chatId == chatId:
            // Chat Info lists messages older than the loaded history, and a transcription asked
            // for there arrives as a change of content too.
            if let shared = sharedMedia.message(update.messageId),
               let body = body(for: update.newContent, isOutgoing: shared.isOutgoing, sender: shared.sender) {
                sharedMedia.replaceBody(of: update.messageId, with: body)
                if sharedMedia.message(update.messageId)?.transcription != nil { requestedTranscriptions.remove(update.messageId) }
            }
            guard let index = index(of: update.messageId) else { return }
            if let text = Self.editableText(update.newContent) { formattedTexts[update.messageId] = text }
            let message = messages[index]
            if let body = body(for: update.newContent, isOutgoing: message.isOutgoing, sender: message.sender) {
                updateMessage(at: index) { $0.body = body }
                refreshQuotes(of: [messages[index]])
                sharedMedia.replaceBody(of: message.id, with: body)
                if messages[index].transcription != nil { requestedTranscriptions.remove(message.id) }
            } else {
                remove([message.id])
            }
        case .updateMessageInteractionInfo(let update) where update.chatId == chatId:
            guard let index = index(of: update.messageId) else { return }
            let reactions = Self.reactions(update.interactionInfo)
            updateMessage(at: index) { $0.reactions = reactions }
        case .updateMessageContentOpened(let update) where update.chatId == chatId:
            sharedMedia.markListened(update.messageId)
            guard let index = index(of: update.messageId),
                  case .voiceNote(var note, let caption) = messages[index].body else { return }
            note.isListened = true
            updateMessage(at: index) { $0.body = .voiceNote(note, caption: caption) }
        case .updateMessageEdited(let update) where update.chatId == chatId:
            guard let index = index(of: update.messageId) else { return }
            updateMessage(at: index) { $0.isEdited = true }
        case .updateDeleteMessages(let update) where update.chatId == chatId && update.isPermanent:
            remove(update.messageIds)
            markRepliesDeleted(to: update.messageIds)
        case .updateChatReadOutbox(let update) where update.chatId == chatId:
            lastReadOutboxMessageId = update.lastReadOutboxMessageId
        case .updateChatAction(let update) where update.chatId == chatId:
            updateTyping(update)
        default:
            break
        }
    }

    // MARK: Building messages

    /// Adds new messages and replaces changed ones. New messages at the bottom (the usual case)
    /// and older history are added in one step; anything else goes in one by one, in id order.
    private func merge(_ newMessages: [Message]) {
        guard !newMessages.isEmpty else { return }
        // The last copy of each message wins; nil for content Hushh leaves out.
        var incoming: [(id: Int64, model: MessageModel?)] = []
        var seen: Set<Int64> = []
        for message in newMessages.reversed() where seen.insert(message.id).inserted {
            incoming.append((message.id, model(for: message)))
        }
        incoming.sort { $0.id < $1.id }
        resolveReplies(in: &incoming)
        let models = incoming.compactMap(\.model)

        if let lastId = messages.last?.id, incoming[0].id > lastId {
            let firstNew = messages.count
            messages += models
            messagesChanged(from: firstNew)
        } else if let firstId = messages.first?.id, incoming[incoming.count - 1].id < firstId {
            messages.insert(contentsOf: models, at: 0)
            messagesChanged(from: 0)
        } else {
            // Messages that only changed keep their row; the first one added or removed decides
            // where the timeline is built again.
            var firstInsertOrRemoval: Int?
            for (id, model) in incoming {
                let index = insertionIndex(of: id)
                let exists = index < messages.count && messages[index].id == id
                switch (exists, model) {
                case (true, let model?):
                    if firstInsertOrRemoval == nil {
                        updateMessage(at: index) { $0 = model }
                    } else {
                        messages[index] = model
                    }
                case (true, nil):
                    messages.remove(at: index)
                    firstInsertOrRemoval = min(firstInsertOrRemoval ?? index, index)
                case (false, let model?):
                    messages.insert(model, at: index)
                    firstInsertOrRemoval = min(firstInsertOrRemoval ?? index, index)
                case (false, nil):
                    break
                }
            }
            if let firstInsertOrRemoval { messagesChanged(from: firstInsertOrRemoval) }
        }
        refreshQuotes(of: models)
        if !failedReplyLookups.isEmpty { retryFailedReplyLookups() }
    }

    /// The text editing starts from: a text message's, or a lone emoji's (Telegram sends a
    /// single emoji as an animated one). Nil for everything else, dice included.
    private static func editableText(_ content: MessageContent) -> FormattedText? {
        switch content {
        case .messageText(let text): text.text
        case .messageAnimatedEmoji(let emoji): FormattedText(entities: [], text: emoji.emoji)
        default: nil
        }
    }

    /// A message that was sending now has its final id (or failed): the reply bar and the
    /// viewer follow it.
    private func replace(_ oldId: Int64, with message: Message) {
        let wasReplyTarget = replyingTo?.id == oldId
        let wasInViewer = viewerMessageId == oldId
        remove([oldId])
        merge([message])
        if wasReplyTarget { replyingTo = messages.first { $0.id == message.id } }
        if wasInViewer, messages.contains(where: { $0.id == message.id }) { viewerMessageId = message.id }
    }

    private func remove(_ ids: [Int64]) {
        let ids = Set(ids)
        sharedMedia.remove(ids)
        // The composer mustn't keep pointing at a message that's gone. An edit's text stays.
        if let reply = replyingTo, ids.contains(reply.id) { replyingTo = nil }
        if let edited = editing, ids.contains(edited.id) {
            editing = nil
            editingSource = nil
            if !textBeforeEditing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                composerText += "\n" + textBeforeEditing
            }
            errorMessage = "The message you were editing was deleted. Its new text is still in the message box."
        }
        let indices = ids.compactMap(index(of:))
        guard let first = indices.min() else { return }
        for index in indices.sorted(by: >) {
            messages.remove(at: index)
        }
        messagesChanged(from: first)
    }

    /// Changes one loaded message. Its row is updated in place unless the change moves it to
    /// another group or album.
    private func updateMessage(at index: Int, _ change: (inout MessageModel) -> Void) {
        let old = messages[index]
        change(&messages[index])
        let new = messages[index]
        guard new != old else { return }
        if !Timeline.replace(new, in: &timeline) {
            messagesChanged(from: index)
        }
    }

    /// Builds the timeline again from the first changed message on.
    private func messagesChanged(from index: Int) {
        // When the first unread message goes, the divider moves to the next one you haven't read.
        if let unread = firstUnreadMessageId, self.index(of: unread) == nil {
            firstUnreadMessageId = messages[insertionIndex(of: unread)...].first { !$0.isOutgoing }?.id
            return  // which rebuilt the timeline
        }
        Timeline.update(&timeline, messages: messages, changedFrom: index, firstUnreadMessageId: firstUnreadMessageId)
    }

    /// The position of a loaded message, found by halving: `messages` is in id order.
    private func index(of id: Int64) -> Int? {
        let index = insertionIndex(of: id)
        return index < messages.count && messages[index].id == id ? index : nil
    }

    /// Where a message with this id is, or would go.
    private func insertionIndex(of id: Int64) -> Int {
        var low = 0
        var high = messages.count
        while low < high {
            let middle = (low + high) / 2
            if messages[middle].id < id { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private func model(for message: Message) -> MessageModel? {
        let sender = sender(of: message.senderId)
        guard var body = body(for: message.content, isOutgoing: message.isOutgoing, sender: sender) else { return nil }
        if message.selfDestructType != nil { body = MessageMapper.selfDestructingPlaceholder }
        if message.isOutgoing, let text = Self.editableText(message.content) {
            formattedTexts[message.id] = text
        }

        var replyToMessageId: Int64?
        var reply: ReplyPreview?
        switch message.replyTo {
        case .messageReplyToMessage(let target) where target.chatId == chatId || target.chatId == 0:
            replyToMessageId = target.messageId
        case .messageReplyToMessage(let target):
            // A reply to a message in another chat carries its own copy of that message.
            let name = target.origin.map(originName) ?? ""
            reply = ReplyPreview(senderName: name, text: target.content.map(MessagePreview.text) ?? "Message")
        case .messageReplyToStory:
            reply = ReplyPreview(senderName: "", text: "Story")
        case nil:
            break
        }

        let status: MessageModel.Status = switch message.sendingState {
        case .messageSendingStatePending: .sending
        case .messageSendingStateFailed(let failure): .failed(failure.error.message)
        case nil: .sent
        }

        return MessageModel(
            id: message.id,
            date: Foundation.Date(timeIntervalSince1970: TimeInterval(message.date)),
            isOutgoing: message.isOutgoing,
            sender: sender,
            body: body,
            replyToMessageId: replyToMessageId,
            reply: reply,
            forwardedFrom: message.forwardInfo.map { originName($0.origin) },
            isEdited: message.editDate > 0,
            status: status,
            albumId: message.mediaAlbumId.rawValue,
            reactions: Self.reactions(message.interactionInfo)
        )
    }

    private static func reactions(_ info: MessageInteractionInfo?) -> [Reaction] {
        (info?.reactions?.reactions ?? []).map { reaction in
            let kind: Reaction.Kind = switch reaction.type {
            case .reactionTypeEmoji(let emoji): .emoji(emoji.emoji)
            case .reactionTypeCustomEmoji(let custom): .customEmoji(custom.customEmojiId.rawValue)
            case .reactionTypePaid: .paid
            }
            return Reaction(kind: kind, count: reaction.totalCount, isChosen: reaction.isChosen)
        }
    }

    private func body(for content: MessageContent, isOutgoing: Bool, sender: MessageModel.Sender) -> MessageModel.Body? {
        MessageMapper.body(
            for: content,
            isOutgoing: isOutgoing,
            senderId: sender.id,
            senderName: isOutgoing ? "You" : sender.name,
            name: { [chats] in chats.person($0)?.firstName ?? "someone" }
        )
    }

    private func sender(of senderId: MessageSender) -> MessageModel.Sender {
        switch senderId {
        case .messageSenderUser(let user):
            let person = chats.person(user.userId)
            return MessageModel.Sender(
                id: user.userId,
                name: person?.name ?? "Deleted Account",
                accentColorId: person?.accentColorId ?? 0,
                photoFileId: person?.photoFileId
            )
        case .messageSenderChat(let chat):
            let item = chats.item(chat.chatId)
            return MessageModel.Sender(
                id: chat.chatId,
                name: item?.title ?? "",
                accentColorId: item?.accentColorId ?? 0,
                photoFileId: item?.photoFileId
            )
        }
    }

    private func originName(_ origin: MessageOrigin) -> String {
        switch origin {
        case .messageOriginUser(let user): chats.person(user.senderUserId)?.name ?? "Unknown"
        case .messageOriginHiddenUser(let user): user.senderName
        case .messageOriginChat(let chat): chats.item(chat.senderChatId)?.title ?? "a group"
        case .messageOriginChannel(let channel): chats.item(channel.chatId)?.title ?? "a channel"
        }
    }

    /// Fills in the quoted message for replies: from what's loaded if possible, otherwise from TDLib.
    private func resolveReplies(in incoming: inout [(id: Int64, model: MessageModel?)]) {
        for index in incoming.indices {
            guard var message = incoming[index].model, message.reply == nil, let targetId = message.replyToMessageId else { continue }
            if let target = incoming.first(where: { $0.id == targetId })?.model ?? self.index(of: targetId).map({ messages[$0] }) {
                message.reply = Self.quote(of: target)
            } else if let cached = replyCache[targetId] {
                message.reply = cached
            } else if replyLookups.insert(targetId).inserted {
                lookUpReply(targetId: targetId, fromMessageId: message.id)
            }
            incoming[index].model = message
        }
    }

    /// Replies quote what a message says now: after it changes or turns up, their quotes follow.
    private func refreshQuotes(of targets: [MessageModel]) {
        guard !targets.isEmpty else { return }
        let quotes = Dictionary(targets.map { ($0.id, Self.quote(of: $0)) }, uniquingKeysWith: { _, last in last })
        // A reply comes after the message it quotes.
        guard let oldest = targets.map(\.id).min() else { return }
        for index in insertionIndex(of: oldest)..<messages.count {
            guard let targetId = messages[index].replyToMessageId, let quote = quotes[targetId] else { continue }
            if messages[index].reply != quote { updateMessage(at: index) { $0.reply = quote } }
        }
    }

    /// Replies to messages that were deleted say so.
    private func markRepliesDeleted(to ids: [Int64]) {
        for id in ids {
            replyCache[id] = Self.deletedQuote
        }
        let ids = Set(ids)
        for index in messages.indices {
            guard let targetId = messages[index].replyToMessageId, ids.contains(targetId) else { continue }
            if messages[index].reply != Self.deletedQuote { updateMessage(at: index) { $0.reply = Self.deletedQuote } }
        }
    }

    private static let deletedQuote = ReplyPreview(senderName: "", text: "Deleted message")

    private static func quote(of message: MessageModel) -> ReplyPreview {
        ReplyPreview(senderName: message.isOutgoing ? "You" : message.sender.name, text: message.previewText)
    }

    /// Asks TDLib for a quoted message that isn't loaded. Only TDLib's "not found" counts as
    /// deleted; after any other failure (offline, say) the next merge asks again.
    private func lookUpReply(targetId: Int64, fromMessageId: Int64) {
        let chatId = chatId
        let client = client
        Task {
            let preview: ReplyPreview
            do {
                let replied = try await client.resilientRepliedMessage(chatId: chatId, messageId: fromMessageId)
                let sender = sender(of: replied.senderId)
                preview = ReplyPreview(
                    senderName: replied.isOutgoing ? "You" : sender.name,
                    text: MessagePreview.text(for: replied.content)
                )
            } catch let error as TDLibKit.Error where error.code == 404 {
                preview = Self.deletedQuote
            } catch {
                replyLookups.remove(targetId)
                failedReplyLookups[targetId] = fromMessageId
                return
            }
            replyCache[targetId] = preview
            for index in messages.indices where messages[index].replyToMessageId == targetId && messages[index].reply == nil {
                updateMessage(at: index) { $0.reply = preview }
            }
        }
    }

    /// Asks again for quotes whose lookup failed, unless the quoted message has turned up since.
    private func retryFailedReplyLookups() {
        let failed = failedReplyLookups
        failedReplyLookups = [:]
        for (targetId, fromMessageId) in failed where index(of: targetId) == nil && replyLookups.insert(targetId).inserted {
            lookUpReply(targetId: targetId, fromMessageId: fromMessageId)
        }
    }

    // MARK: Typing

    private func updateTyping(_ update: UpdateChatAction) {
        let senderId: Int64 = switch update.senderId {
        case .messageSenderUser(let user): user.userId
        case .messageSenderChat(let chat): chat.chatId
        }
        let existing = typing.firstIndex { $0.senderId == senderId }
        if case .chatActionCancel = update.action {
            if let existing { typing.remove(at: existing) }
        } else if let existing {
            typing[existing].activity = Self.activity(update.action)
        } else {
            typing.append((senderId, update.senderId, Self.activity(update.action)))
        }
        let typingText = describeTyping()
        if self.typingText != typingText { self.typingText = typingText }
        let typist = typing.first.map { sender(of: $0.sender) }
        if self.typist != typist { self.typist = typist }
    }

    private func describeTyping() -> String? {
        guard let first = typing.first else { return nil }
        guard isGroup else { return "\(first.activity)…" }
        func name(_ id: Int64) -> String { chats.person(id)?.firstName ?? chats.item(id)?.title ?? "Someone" }
        let isOneActivity = typing.allSatisfy { $0.activity == first.activity }
        switch typing.count {
        case 1:
            return "\(name(first.senderId)) is \(first.activity)…"
        case 2 where isOneActivity:
            return "\(name(first.senderId)) and \(name(typing[1].senderId)) are \(first.activity)…"
        case 2:
            return "\(name(first.senderId)) is \(first.activity) and \(name(typing[1].senderId)) is \(typing[1].activity)…"
        default:
            return isOneActivity ? "Several people are \(first.activity)…" : "Several people are busy…"
        }
    }

    private static func activity(_ action: ChatAction) -> String {
        switch action {
        case .chatActionRecordingVoiceNote, .chatActionUploadingVoiceNote: "recording a voice message"
        case .chatActionRecordingVideoNote, .chatActionUploadingVideoNote: "recording a video message"
        case .chatActionUploadingPhoto: "sending a photo"
        case .chatActionRecordingVideo, .chatActionUploadingVideo: "sending a video"
        case .chatActionUploadingDocument: "sending a file"
        case .chatActionChoosingSticker: "choosing a sticker"
        default: "typing"
        }
    }

    // Nonisolated, so the TDLib values they build can be handed to TDLib's background queues.
    private nonisolated static func replyTo(_ messageId: Int64?) -> InputMessageReplyTo? {
        messageId.map {
            .inputMessageReplyToMessage(InputMessageReplyToMessage(checklistTaskId: 0, messageId: $0, pollOptionId: "", quote: nil))
        }
    }

    private nonisolated static func draftMessage(_ text: String) -> DraftMessage? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return DraftMessage(
            content: .draftMessageContentText(DraftMessageContentText(linkPreviewOptions: nil, text: FormattedText(entities: [], text: text))),
            date: Int(Foundation.Date.now.timeIntervalSince1970),
            effectId: 0,
            replyTo: nil,
            suggestedPostInfo: nil
        )
    }
}
