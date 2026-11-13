import AppKit
import Foundation
@preconcurrency import TDLibKit
@testable import HushCore

/// TDLib values made by hand, and a conversation on a TDLib client that never logs in.
enum Fixtures {
    /// Your own user id.
    static let me: Int64 = 1000
    /// The chat a conversation opens when a test names no other.
    static let chatId: Int64 = 100
    static let date = 1_763_000_000

    // MARK: Messages

    static func text(_ string: String, entities: [TextEntity] = []) -> MessageContent {
        .messageText(MessageText(linkPreview: nil, linkPreviewOptions: nil, text: FormattedText(entities: entities, text: string)))
    }

    /// A message in `chat`. Without `sender` it comes from you when outgoing, and otherwise from
    /// the chat's other person (a private chat has its user's id).
    static func message(
        _ id: Int64,
        _ content: MessageContent,
        chat: Int64 = chatId,
        from sender: Int64? = nil,
        outgoing: Bool = false,
        date: Int = date,
        editDate: Int = 0,
        replyTo: MessageReplyTo? = nil,
        forward: MessageForwardInfo? = nil,
        interaction: MessageInteractionInfo? = nil,
        album: Int64 = 0,
        sending: MessageSendingState? = nil
    ) -> Message {
        Message(
            authorSignature: "", autoDeleteIn: 0, canBeSaved: true, chatId: chat, chatInstance: 0,
            containsUnreadMention: false, containsUnreadPollVotes: false, content: content, date: date,
            editDate: editDate, effectId: 0, ephemeralContent: nil, ephemeralMessageId: 0, factCheck: nil,
            forwardInfo: forward, guestBotCallerId: nil, hasTimestampedMedia: false, id: id, importInfo: nil,
            interactionInfo: interaction, isChannelPost: false, isFromOffline: false, isOutgoing: outgoing,
            isPaidGramSuggestedPost: false, isPaidStarSuggestedPost: false, isPinned: false,
            mediaAlbumId: TdInt64(album), paidMessageStarCount: 0, receiverId: nil, replyMarkup: nil,
            replyTo: replyTo, restrictionInfo: nil, schedulingState: nil, selfDestructIn: 0, selfDestructType: nil,
            senderBoostCount: 0, senderBusinessBotUserId: 0,
            senderId: .messageSenderUser(MessageSenderUser(userId: sender ?? (outgoing ? me : chat))),
            senderTag: "", sendingState: sending, suggestedPostInfo: nil, summaryLanguageCode: "",
            topicId: nil, unreadReactions: [], viaBotUserId: 0
        )
    }

    static func reply(to messageId: Int64, in chat: Int64 = chatId) -> MessageReplyTo {
        .messageReplyToMessage(MessageReplyToMessage(
            chatId: chat, checklistTaskId: 0, content: nil, messageId: messageId, origin: nil,
            originSendDate: 0, pollOptionId: "", quote: nil
        ))
    }

    static func reactions(_ reactions: [MessageReaction]) -> MessageInteractionInfo {
        MessageInteractionInfo(
            forwardCount: 0,
            reactions: MessageReactions(areTags: false, canGetAddedReactions: false, paidReactors: [], reactions: reactions),
            replyInfo: nil, viewCount: 0
        )
    }

    static func newMessage(_ message: Message) -> Update {
        .updateNewMessage(UpdateNewMessage(message: message))
    }

    static func voiceNote(fileId: Int, isListened: Bool = false, speech: SpeechRecognitionResult? = nil) -> MessageContent {
        .messageVoiceNote(MessageVoiceNote(
            caption: FormattedText(entities: [], text: ""), isListened: isListened,
            voiceNote: VoiceNote(duration: 3, mimeType: "audio/ogg", speechRecognitionResult: speech, voice: file(fileId), waveform: Data())
        ))
    }

    static func file(_ id: Int, path: String = "", completed: Bool = false) -> File {
        File(
            expectedSize: 0, id: id,
            local: LocalFile(
                canBeDeleted: true, canBeDownloaded: true, downloadOffset: 0, downloadedPrefixSize: 0,
                downloadedSize: 0, isDownloadingActive: false, isDownloadingCompleted: completed, path: path
            ),
            remote: RemoteFile(id: "", isUploadingActive: false, isUploadingCompleted: true, uniqueId: "", uploadedSize: 0),
            size: 1000
        )
    }

    // MARK: Chats

    /// A chat; without `type`, the private chat with user `id`.
    static func chat(
        _ id: Int64 = chatId, _ title: String = "Test chat", type: ChatType? = nil, positions: [ChatPosition] = [],
        last: Message? = nil, unread: Int = 0, mentions: Int = 0, markedUnread: Bool = false, lastReadInbox: Int64 = 0,
        notification: ChatNotificationSettings = notificationSettings(), draft: String? = nil
    ) -> Chat {
        Chat(
            accentColorId: Int(abs(id) % 7), actionBar: nil,
            availableReactions: .chatAvailableReactionsAll(ChatAvailableReactionsAll(maxReactionCount: 11)),
            background: nil, backgroundCustomEmojiId: 0, blockList: nil, businessBotManageBar: nil,
            canBeDeletedForAllUsers: false, canBeDeletedOnlyForSelf: true, canBeReported: false, chatLists: [],
            clientData: "", defaultDisableNotification: false, draftMessage: draft.map(draftMessage),
            emojiStatus: nil, hasProtectedContent: false, hasScheduledMessages: false, hasWelcomeMessages: false,
            id: id, isMarkedAsUnread: markedUnread, isTranslatable: false, lastMessage: last,
            lastReadInboxMessageId: lastReadInbox, lastReadOutboxMessageId: 0, messageAutoDeleteTime: 0,
            messageSenderId: nil, notificationSettings: notification, pendingJoinRequests: nil,
            permissions: ChatPermissions(
                canAddLinkPreviews: true, canChangeInfo: true, canCreateTopics: true, canEditTag: true,
                canInviteUsers: true, canPinMessages: true, canReactToMessages: true, canSendAudios: true,
                canSendBasicMessages: true, canSendDocuments: true, canSendOtherMessages: true, canSendPhotos: true,
                canSendPolls: true, canSendVideoNotes: true, canSendVideos: true, canSendVoiceNotes: true
            ),
            photo: nil, positions: positions, profileAccentColorId: 0, profileBackgroundCustomEmojiId: 0,
            replyMarkupMessageId: 0, theme: nil, title: title, type: type ?? .chatTypePrivate(ChatTypePrivate(userId: id)),
            unreadCount: unread, unreadMentionCount: mentions, unreadPollVoteCount: 0, unreadReactionCount: 0,
            upgradedGiftColors: nil, videoChat: VideoChat(defaultParticipantId: nil, groupCallId: 0, hasParticipants: false),
            viewAsTopics: false
        )
    }

    static func basicGroup(_ id: Int64) -> ChatType { .chatTypeBasicGroup(ChatTypeBasicGroup(basicGroupId: id)) }
    static func supergroup(_ id: Int64) -> ChatType { .chatTypeSupergroup(ChatTypeSupergroup(isChannel: false, supergroupId: id)) }
    static func channel(_ id: Int64) -> ChatType { .chatTypeSupergroup(ChatTypeSupergroup(isChannel: true, supergroupId: id)) }

    /// Where a chat sits in a list; a higher order comes first.
    static func position(_ order: Int64, list: ChatList = .chatListMain, pinned: Bool = false) -> ChatPosition {
        ChatPosition(isPinned: pinned, list: list, order: TdInt64(order), source: nil)
    }

    /// The chat's own settings; with `useDefault`, the default for its kind decides about muting.
    static func notificationSettings(muteFor: Int = 0, useDefault: Bool = true) -> ChatNotificationSettings {
        ChatNotificationSettings(
            disableMentionNotifications: false, disablePinnedMessageNotifications: false, muteFor: muteFor,
            muteStories: false, showPreview: true, showStoryPoster: false, soundId: 0, storySoundId: 0,
            useDefaultDisableMentionNotifications: true, useDefaultDisablePinnedMessageNotifications: true,
            useDefaultMuteFor: useDefault, useDefaultMuteStories: true, useDefaultShowPreview: true,
            useDefaultShowStoryPoster: true, useDefaultSound: true, useDefaultStorySound: true
        )
    }

    static func draftMessage(_ text: String) -> DraftMessage {
        DraftMessage(
            content: .draftMessageContentText(DraftMessageContentText(linkPreviewOptions: nil, text: FormattedText(entities: [], text: text))),
            date: date, effectId: 0, replyTo: nil, suggestedPostInfo: nil
        )
    }

    // MARK: Users

    static func user(
        _ id: Int64, _ firstName: String, _ lastName: String = "", type: UserType = .userTypeRegular,
        status: UserStatus = .userStatusEmpty
    ) -> User {
        User(
            accentColorId: 0, activeStoryState: nil, addedToAttachmentMenu: false, backgroundCustomEmojiId: 0,
            emojiStatus: nil, firstName: firstName, haveAccess: true, id: id, isCloseFriend: false, isContact: true,
            isMutualContact: true, isPremium: false, isSupport: false, languageCode: "en", lastName: lastName,
            paidMessageStarCount: 0, phoneNumber: "", profileAccentColorId: 0, profileBackgroundCustomEmojiId: 0,
            profilePhoto: nil, restrictionInfo: nil, restrictsNewChats: false, status: status, type: type,
            upgradedGiftColors: nil, usernames: nil, verificationStatus: nil
        )
    }

    static let botType: UserType = .userTypeBot(UserTypeBot(
        activeUserCount: 0, allowsUsersToCreateTopics: false, canBeAddedToAttachmentMenu: false, canBeEdited: false,
        canConnectToBusiness: false, canJoinGroups: true, canManageBots: false, canReadAllGroupMessages: false,
        hasMainWebApp: false, hasTopics: false, inlineQueryPlaceholder: "", isGuard: false, isInline: false,
        needLocation: false, supportsGuestQueries: false
    ))

    // MARK: Stores and conversations

    /// A TDLib client that is never given its parameters, so it never connects or logs in: every
    /// request that needs a session fails. It is closed when the test process exits, because a
    /// client still open then crashes the process on its way out.
    @MainActor static let session: TDSession = {
        let session = TDSession()
        atexit { TDSession.closeAll() }
        return session
    }()

    /// A store with its visibility settings in a fresh temporary folder, and no TDLib client.
    @MainActor
    static func store() -> ChatStore {
        let store = ChatStore(files: FileStore())
        store.visibility.load(from: FileManager.default.temporaryDirectory.appending(path: "hush-test-\(UUID().uuidString)/visibility.json"))
        return store
    }

    /// A conversation in `chat` on a client that never logs in, so every request to Telegram fails,
    /// as it does offline, while local work such as reading Markdown still runs. The chat and
    /// `users` go into `store` first; `kind` overrides what the store guesses.
    @MainActor
    static func conversation(
        _ chat: Chat = chat(), kind: ChatKind = .person, users: [User] = [], store: ChatStore? = nil,
        session: TDSession = session
    ) -> (ConversationModel, ChatStore, ChatItem) {
        _ = NSApplication.shared  // ConversationModel reads NSApp.isActive
        let store = store ?? ChatStore(files: FileStore())
        for user in users { store.handle(.updateUser(UpdateUser(user: user))) }
        store.handle(.updateNewChat(UpdateNewChat(chat: chat)))
        let item = store.item(chat.id) ?? ChatItem(chat)
        item.kind = kind
        let model = ConversationModel(chat: item, client: session.client, chats: store, voice: VoicePlayback())
        return (model, store, item)
    }

    // MARK: Waiting and files

    /// Waits long enough for work started a moment ago to finish: the store's lists rebuild
    /// 100 ms after an update, and requests to a client that never logs in fail at once.
    static func settle(_ milliseconds: Int = 250) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    /// Waits until the condition holds, checking every 20 ms for about `seconds`; longer on a busy
    /// machine, where TDLib answers late too.
    @MainActor
    static func wait(upTo seconds: Double = 5, until condition: () -> Bool) async {
        for _ in 0 ..< Int(seconds * 50) where !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A new, empty folder in the temporary directory.
    static func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "hush-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A file called `name` holding `contents`, alone in a new temporary folder.
    static func temporaryFile(_ name: String, contents: Data = Data("hello".utf8)) throws -> URL {
        let url = try temporaryFolder().appending(path: name)
        try contents.write(to: url)
        return url
    }

    /// A PNG picture, four pixels high.
    static func png(width: Int) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }
}
