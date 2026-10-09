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
    /// False in channels where you aren't an admin: you can read and react, not post.
    public let canPost: Bool
    /// Telegram's sponsored message for this channel, shown below the last post.
    public private(set) var sponsoredAd: SponsoredAd?
    /// Set while Telegram asks why you're reporting the ad.
    public var sponsoredReport: SponsoredReport?
    /// Oldest first.
    public private(set) var messages: [MessageModel] = [] {
        didSet { rebuildTimeline() }
    }
    /// The rows the conversation shows, rebuilt only when messages change rather than on every redraw.
    public private(set) var timeline: [TimelineItem] = []
    public private(set) var hasOlderMessages = true
    public private(set) var isLoadingInitial = true
    /// The first message you hadn't read when the chat opened. The "Unread Messages" divider sits
    /// above it and stays put while you read.
    public private(set) var firstUnreadMessageId: Int64? {
        didSet { rebuildTimeline() }
    }
    /// Your messages up to this one have been read by the other side.
    public private(set) var lastReadOutboxMessageId: Int64
    /// "Alex is typing…", or nil.
    public private(set) var typingText: String?
    public var errorMessage: String?

    public var composerText: String
    /// Files waiting to go out with the next send.
    public private(set) var attachments: [Attachment] = []
    /// The file shown in Quick Look, if any. Photos and videos use Hushh's viewer instead.
    public var quickLookURL: URL?
    /// The photo or video open in the viewer.
    public private(set) var viewerMessageId: Int64?
    public private(set) var replyingTo: MessageModel?
    public private(set) var editing: MessageModel?
    public var pendingDeletion: PendingDeletion?
    /// Bumped whenever the composer should take keyboard focus.
    public private(set) var focusRequest = 0
    public let recorder = VoiceRecorder()
    public let voice: VoicePlayback

    @ObservationIgnored private let client: TDLibClient
    @ObservationIgnored private let chats: ChatStore
    @ObservationIgnored private var savedDraft: String
    @ObservationIgnored private var textBeforeEditing = ""
    /// The formatted text of your own messages, so editing keeps their formatting.
    @ObservationIgnored private var formattedTexts: [Int64: FormattedText] = [:]
    @ObservationIgnored private var oldestLoadedId: Int64?
    public private(set) var isLoadingOlder = false
    @ObservationIgnored private var replyCache: [Int64: ReplyPreview] = [:]
    @ObservationIgnored private var replyLookups: Set<Int64> = []
    @ObservationIgnored private var typing: [Int64: String] = [:]
    @ObservationIgnored private var visibleIds: Set<Int64> = []
    @ObservationIgnored private var viewedIds: Set<Int64> = []
    @ObservationIgnored private var isViewingScheduled = false
    @ObservationIgnored private var lastTypingSent = Foundation.Date.distantPast
    @ObservationIgnored private var isOpen = false
    @ObservationIgnored private var isSponsoredAdViewed = false

    init(chat: ChatItem, client: TDLibClient, chats: ChatStore, voice: VoicePlayback) {
        self.voice = voice
        chatId = chat.id
        isGroup = chat.kind == .group
        isChannel = chat.kind == .channel
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
                errorMessage = AuthModel.describe(error)
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
        let draft = editing == nil ? composerText : textBeforeEditing
        let draftChanged = draft != savedDraft
        let chatId = chatId
        let client = client
        Task {
            if draftChanged {
                _ = try? await client.setChatDraftMessage(chatId: chatId, draftMessage: Self.draftMessage(draft), topicId: nil)
            }
            _ = try? await client.closeChat(chatId: chatId)
        }
    }

    /// Loads the page of history before the oldest loaded message. Returns whether it found any.
    /// `afterMerge` runs in the same step that adds the page, so the view can adjust its scroll
    /// position before anything is drawn.
    @discardableResult
    public func loadOlder(afterMerge: () -> Void = {}) async -> Bool {
        guard hasOlderMessages, !isLoadingOlder, !isLoadingInitial, let oldestId = oldestLoadedId else { return false }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        let page: [Message]
        do {
            page = try await client.resilientChatHistory(chatId: chatId, fromMessageId: oldestId, limit: 50).messages ?? []
        } catch {
            errorMessage = AuthModel.describe(error)
            return false
        }
        let older = page.filter { $0.id < oldestId }
        guard let oldest = older.last else {
            hasOlderMessages = false
            return false
        }
        oldestLoadedId = oldest.id
        merge(older)
        afterMerge()
        return true
    }

    private func rebuildTimeline() {
        timeline = Timeline.build(messages, firstUnreadMessageId: firstUnreadMessageId)
    }

    // MARK: Composer

    public var canSend: Bool {
        !attachments.isEmpty || !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func send() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        if editing == nil, !attachments.isEmpty {
            sendAttachments(caption: text)
            return
        }
        guard !text.isEmpty else { return }
        let editedMessageId = editing?.id
        let replyToMessageId = replyingTo?.id
        // Clear right away; TDLib shows the new message as sending within milliseconds.
        if editedMessageId != nil {
            editing = nil
            composerText = textBeforeEditing
        } else {
            composerText = ""
            replyingTo = nil
            savedDraft = ""  // sending clears the draft
        }
        lastTypingSent = .distantPast
        let chatId = chatId
        let client = client
        Task {
            do {
                // **bold**, __italic__, ~~strikethrough~~, ||spoiler||, `code` and [links](https://…).
                let formatted = try await client.parseMarkdown(text: FormattedText(entities: [], text: text))
                let content = InputMessageContent.inputMessageText(InputMessageText(clearDraft: true, linkPreviewOptions: nil, text: formatted))
                if let editedMessageId {
                    _ = try await client.editMessageText(chatId: chatId, inputMessageContent: content, messageId: editedMessageId, replyMarkup: nil)
                } else {
                    _ = try await client.sendMessage(
                        chatId: chatId, inputMessageContent: content, options: nil, replyMarkup: nil,
                        replyTo: Self.replyTo(replyToMessageId), topicId: nil
                    )
                }
            } catch {
                errorMessage = AuthModel.describe(error)
                if composerText.isEmpty { composerText = text }  // don't lose what you wrote
            }
        }
    }

    // MARK: Attachments, stickers and GIFs

    /// Adds files to send (from the attach button, drag and drop, or paste). `asFiles` sends
    /// pictures and videos as files, in original quality, rather than compressed.
    public func attach(_ urls: [URL], asFiles: Bool = false) {
        let files = urls.filter(\.isFileURL)
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
        let replyToMessageId = replyingTo?.id
        replyingTo = nil
        let chatId = chatId
        let client = client
        Task {
            do {
                try await Self.sendSticker(sticker, replyToMessageId: replyToMessageId, chatId: chatId, client: client)
            } catch {
                errorMessage = AuthModel.describe(error)
            }
        }
    }

    public func sendGIF(_ gif: VideoMedia) {
        let replyToMessageId = replyingTo?.id
        replyingTo = nil
        let chatId = chatId
        let client = client
        Task {
            do {
                try await Self.sendGIF(gif, replyToMessageId: replyToMessageId, chatId: chatId, client: client)
            } catch {
                errorMessage = AuthModel.describe(error)
            }
        }
    }

    private func sendAttachments(caption: String) {
        let items = attachments
        let replyToMessageId = replyingTo?.id
        attachments = []
        composerText = ""
        replyingTo = nil
        savedDraft = ""
        let chatId = chatId
        let client = client
        Task {
            do {
                try await Self.sendAttachments(items, caption: caption, replyToMessageId: replyToMessageId, chatId: chatId, client: client)
            } catch {
                errorMessage = AuthModel.describe(error)
            }
        }
    }

    /// Photos and videos go out together as an album (up to 10 per album, Telegram's limit);
    /// other files follow one by one. The caption goes on the first item.
    private nonisolated static func sendAttachments(
        _ items: [Attachment], caption: String, replyToMessageId: Int64?, chatId: Int64, client: TDLibClient
    ) async throws {
        let formattedCaption = caption.isEmpty ? nil : try await client.parseMarkdown(text: FormattedText(entities: [], text: caption))
        let mediaItems = items.filter { $0.kind != .file }
        let fileItems = items.filter { $0.kind == .file }
        var media: [InputMessageContent] = []
        for (index, item) in mediaItems.enumerated() {
            media.append(await AttachmentPreparer.content(for: item, caption: index == 0 ? formattedCaption : nil))
        }
        let files = fileItems.enumerated().map { index, item in
            AttachmentPreparer.document(item, caption: mediaItems.isEmpty && index == 0 ? formattedCaption : nil)
        }

        var replyTo = Self.replyTo(replyToMessageId)
        for start in stride(from: 0, to: media.count, by: 10) {
            let album = Array(media[start ..< min(start + 10, media.count)])
            if album.count == 1 {
                _ = try await client.sendMessage(chatId: chatId, inputMessageContent: album[0], options: nil, replyMarkup: nil, replyTo: replyTo, topicId: nil)
            } else {
                _ = try await client.sendMessageAlbum(chatId: chatId, inputMessageContents: album, options: nil, replyTo: replyTo, topicId: nil)
            }
            replyTo = nil
        }
        for content in files {
            _ = try await client.sendMessage(chatId: chatId, inputMessageContent: content, options: nil, replyMarkup: nil, replyTo: replyTo, topicId: nil)
            replyTo = nil
        }
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
        viewerMessageId.flatMap { id in messages.first { $0.id == id } }
    }

    /// This chat's photos and videos, oldest first, to step through in the viewer.
    public var viewableMedia: [MessageModel] {
        messages.filter(\.isViewableMedia)
    }

    public func openViewer(_ message: MessageModel) {
        viewerMessageId = message.id
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
    }

    // MARK: Voice messages

    /// Plays or pauses a voice message. Playing someone's for the first time marks it as listened,
    /// which they see, as in Telegram's own apps.
    public func playVoiceNote(_ message: MessageModel, url: URL) {
        let startedFromBeginning = voice.toggle(messageId: message.id, url: url)
        guard startedFromBeginning, !message.isOutgoing,
              case .voiceNote(let note, _) = message.body, !note.isListened else { return }
        let chatId = chatId
        let client = client
        Task { _ = try? await client.openMessageContent(chatId: chatId, messageId: message.id) }
    }

    public func startRecording() {
        cancelEditing()
        Task {
            do {
                try await recorder.start()
                sendRecordingAction()
            } catch {
                errorMessage = (error as? VoiceRecorder.MicrophoneDenied)?.description ?? AuthModel.describe(error)
            }
        }
    }

    public func cancelRecording() {
        recorder.cancel()
    }

    public func finishRecording() {
        let replyToMessageId = replyingTo?.id
        replyingTo = nil
        let chatId = chatId
        let client = client
        Task {
            do {
                guard let note = try await recorder.finish() else { return }
                try await Self.sendVoiceNote(note, replyToMessageId: replyToMessageId, chatId: chatId, client: client)
            } catch {
                errorMessage = "\(error)"
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

    /// Counts the ad as seen, once its whole text is on screen, as Telegram requires.
    public func sponsoredAdBecameFullyVisible() {
        guard let ad = sponsoredAd, !isSponsoredAdViewed, NSApp.isActive else { return }
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
        cancelEditing()
        replyingTo = message
        focusRequest += 1
    }

    public func cancelReply() {
        replyingTo = nil
    }

    public func startEditing(_ message: MessageModel) {
        guard message.canEditText, let formatted = formattedTexts[message.id] else { return }
        replyingTo = nil
        if editing == nil { textBeforeEditing = composerText }
        editing = message
        composerText = formatted.text
        focusRequest += 1
        let client = client
        Task {
            // Show the formatting as Markdown so saving the edit doesn't drop it.
            guard let markdown = try? await client.getMarkdownText(text: formatted), editing?.id == message.id else { return }
            composerText = markdown.text
        }
    }

    public func cancelEditing() {
        guard editing != nil else { return }
        editing = nil
        composerText = textBeforeEditing
    }

    /// ↑ in an empty composer edits your last message, as in Telegram and Signal.
    public func editLastMessage() -> Bool {
        guard composerText.isEmpty, editing == nil,
              let message = messages.last(where: \.canEditText) else { return false }
        startEditing(message)
        return true
    }

    /// Esc: stop editing, or stop replying.
    public func cancelComposerMode() -> Bool {
        if editing != nil {
            cancelEditing()
            return true
        }
        if replyingTo != nil {
            replyingTo = nil
            return true
        }
        return false
    }

    // MARK: Deleting

    public func requestDeletion(of messages: [MessageModel]) {
        guard let message = messages.first else { return }
        let chatId = chatId
        let client = client
        Task {
            let properties = try? await client.getMessageProperties(chatId: chatId, messageId: message.id)
            let canDeleteForEveryone = properties?.canBeDeletedForAllUsers ?? false
            let canDeleteForMe = properties?.canBeDeletedOnlyForSelf ?? true
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
            remove([update.oldMessageId])
            merge([update.message])
        case .updateMessageSendFailed(let update) where update.message.chatId == chatId:
            remove([update.oldMessageId])
            merge([update.message])
        case .updateMessageContent(let update) where update.chatId == chatId:
            guard let index = messages.firstIndex(where: { $0.id == update.messageId }) else { return }
            if case .messageText(let text) = update.newContent { formattedTexts[update.messageId] = text.text }
            let message = messages[index]
            if let body = body(for: update.newContent, isOutgoing: message.isOutgoing, sender: message.sender) {
                messages[index].body = body
            } else {
                messages.remove(at: index)
            }
        case .updateMessageInteractionInfo(let update) where update.chatId == chatId:
            guard let index = messages.firstIndex(where: { $0.id == update.messageId }) else { return }
            let reactions = Self.reactions(update.interactionInfo)
            if messages[index].reactions != reactions { messages[index].reactions = reactions }
        case .updateMessageContentOpened(let update) where update.chatId == chatId:
            guard let index = messages.firstIndex(where: { $0.id == update.messageId }),
                  case .voiceNote(var note, let caption) = messages[index].body else { return }
            note.isListened = true
            messages[index].body = .voiceNote(note, caption: caption)
        case .updateMessageEdited(let update) where update.chatId == chatId:
            guard let index = messages.firstIndex(where: { $0.id == update.messageId }) else { return }
            messages[index].isEdited = true
        case .updateDeleteMessages(let update) where update.chatId == chatId && update.isPermanent:
            remove(update.messageIds)
        case .updateChatReadOutbox(let update) where update.chatId == chatId:
            lastReadOutboxMessageId = update.lastReadOutboxMessageId
        case .updateChatAction(let update) where update.chatId == chatId:
            updateTyping(update)
        default:
            break
        }
    }

    // MARK: Building messages

    private func merge(_ newMessages: [Message]) {
        guard !newMessages.isEmpty else { return }
        var byId = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for message in newMessages {
            if let model = model(for: message) {
                byId[model.id] = model
            } else {
                byId[message.id] = nil
            }
        }
        var merged = byId.values.sorted { $0.id < $1.id }
        resolveReplies(in: &merged)
        messages = merged
    }

    private func remove(_ ids: [Int64]) {
        let ids = Set(ids)
        guard messages.contains(where: { ids.contains($0.id) }) else { return }
        messages.removeAll { ids.contains($0.id) }
    }

    private func model(for message: Message) -> MessageModel? {
        let sender = sender(of: message.senderId)
        guard var body = body(for: message.content, isOutgoing: message.isOutgoing, sender: sender) else { return nil }
        if message.selfDestructType != nil { body = MessageMapper.selfDestructingPlaceholder }
        if message.isOutgoing, case .messageText(let text) = message.content {
            formattedTexts[message.id] = text.text
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
            case .reactionTypeCustomEmoji: .customEmoji
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
    private func resolveReplies(in messages: inout [MessageModel]) {
        let byId = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in messages.indices {
            guard messages[index].reply == nil, let targetId = messages[index].replyToMessageId else { continue }
            if let target = byId[targetId] {
                messages[index].reply = ReplyPreview(senderName: target.isOutgoing ? "You" : target.sender.name, text: target.previewText)
            } else if let cached = replyCache[targetId] {
                messages[index].reply = cached
            } else if replyLookups.insert(targetId).inserted {
                lookUpReply(targetId: targetId, fromMessageId: messages[index].id)
            }
        }
    }

    private func lookUpReply(targetId: Int64, fromMessageId: Int64) {
        let chatId = chatId
        let client = client
        Task {
            let preview: ReplyPreview
            if let replied = try? await client.resilientRepliedMessage(chatId: chatId, messageId: fromMessageId) {
                let sender = sender(of: replied.senderId)
                preview = ReplyPreview(
                    senderName: replied.isOutgoing ? "You" : sender.name,
                    text: MessagePreview.text(for: replied.content)
                )
            } else {
                preview = ReplyPreview(senderName: "", text: "Deleted message")
            }
            replyCache[targetId] = preview
            var updated = messages
            resolveReplies(in: &updated)
            messages = updated
        }
    }

    // MARK: Typing

    private func updateTyping(_ update: UpdateChatAction) {
        let senderId: Int64 = switch update.senderId {
        case .messageSenderUser(let user): user.userId
        case .messageSenderChat(let chat): chat.chatId
        }
        if case .chatActionCancel = update.action {
            typing[senderId] = nil
        } else {
            typing[senderId] = Self.activity(update.action)
        }
        typingText = describeTyping()
    }

    private func describeTyping() -> String? {
        guard let first = typing.first else { return nil }
        guard isGroup else { return "\(first.value)…" }
        switch typing.count {
        case 1:
            return "\(chats.person(first.key)?.firstName ?? "Someone") is \(first.value)…"
        case 2:
            let names = typing.keys.map { chats.person($0)?.firstName ?? "Someone" }
            return "\(names[0]) and \(names[1]) are typing…"
        default:
            return "Several people are typing…"
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
