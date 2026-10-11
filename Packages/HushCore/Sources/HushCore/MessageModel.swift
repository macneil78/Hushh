@preconcurrency import TDLibKit
import Foundation

/// One message as the conversation shows it.
public struct MessageModel: Identifiable, Equatable, Sendable {
    public enum Body: Equatable, Sendable {
        case text(RichText)
        case photo(PhotoMedia, caption: RichText)
        /// Videos and GIFs.
        case video(VideoMedia, caption: RichText)
        case videoNote(VideoNoteMedia)
        case voiceNote(VoiceNoteMedia, caption: RichText)
        case sticker(StickerMedia)
        /// Files and music.
        case document(DocumentMedia, caption: RichText)
        /// Content Hush only names for now; `label` says what it is ("Voice message", "Poll"…).
        case media(label: String, systemImage: String, caption: RichText)
        /// A grey line in the middle of the conversation ("Alex joined the group").
        case service(String)
        /// Something Hush doesn't show here, like a shared story.
        case placeholder(String)
    }

    public enum Status: Equatable, Sendable {
        case sending
        case failed(String)
        case sent
    }

    public struct Sender: Equatable, Sendable {
        public let id: Int64
        public let name: String
        public let accentColorId: Int
        public let photoFileId: Int?
    }

    public let id: Int64
    public var date: Foundation.Date
    public var isOutgoing: Bool
    public var sender: Sender
    public var body: Body
    public var replyToMessageId: Int64?
    /// What the replied-to message says. Filled in once Hush has found it.
    public var reply: ReplyPreview?
    public var forwardedFrom: String?
    public var isEdited: Bool
    public var status: Status
    /// Photos, videos or files sent together share an album id (0 when not in an album).
    public var albumId: Int64 = 0
    public var reactions: [Reaction] = []

    public var isService: Bool {
        if case .service = body { return true }
        return false
    }

    /// Only your own sent, unforwarded text messages can be edited from Hush.
    public var canEditText: Bool {
        guard isOutgoing, status == .sent, forwardedFrom == nil, case .text = body else { return false }
        return true
    }

    /// The message as plain text: what Copy puts on the clipboard.
    public var plainText: String {
        switch body {
        case .text(let text): text.text
        case .photo(_, let caption), .video(_, let caption), .document(_, let caption), .voiceNote(_, let caption),
             .media(_, _, let caption): caption.text
        case .videoNote, .sticker: ""
        case .service(let text), .placeholder(let text): text
        }
    }

    /// One line describing the message, for reply quotes.
    public var previewText: String {
        func labeled(_ label: String, _ caption: RichText) -> String {
            caption.isEmpty ? label : "\(label): \(caption.text)"
        }
        let text: String = switch body {
        case .text(let text): text.text
        case .photo(_, let caption): labeled("Photo", caption)
        case .video(let video, let caption): labeled(video.isGIF ? "GIF" : "Video", caption)
        case .videoNote: "Video message"
        case .voiceNote(_, let caption): labeled("Voice message", caption)
        case .sticker(let sticker): "\(sticker.emoji) Sticker"
        case .document(let document, let caption): labeled(document.fileName, caption)
        case .media(let label, _, let caption): labeled(label, caption)
        case .service(let text), .placeholder(let text): text
        }
        return text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// Photos and videos (GIFs included) open in Hushh's own viewer.
    /// The voice message's or circle's transcription, if Telegram has made one.
    public var transcription: Transcription? {
        switch body {
        case .voiceNote(let note, _): note.transcription
        case .videoNote(let note): note.transcription
        default: nil
        }
    }

    /// The finished transcript, for search.
    public var transcript: String? {
        if case .done(let text) = transcription, !text.isEmpty { return text }
        return nil
    }

    public var isViewableMedia: Bool {
        switch body {
        case .photo, .video: true
        default: false
        }
    }

    public var caption: RichText? {
        switch body {
        case .photo(_, let caption), .video(_, let caption), .document(_, let caption): caption
        default: nil
        }
    }

    /// The downloadable file behind a photo, video or document, for Quick Look and saving.
    public var fileId: Int? {
        switch body {
        case .photo(let photo, _): photo.image.fileId
        case .video(let video, _): video.fileId
        case .videoNote(let note): note.fileId
        case .document(let document, _): document.fileId
        case .voiceNote(let note, _): note.fileId
        case .text, .sticker, .media, .service, .placeholder: nil
        }
    }
}

/// A reaction under a message, with how many people chose it.
public struct Reaction: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case emoji(String)
        /// A Premium custom emoji. Hush shows only the count.
        case customEmoji
        /// Paid star reactions. Hush shows only the count.
        case paid
    }

    public let kind: Kind
    public let count: Int
    /// Whether you chose it.
    public let isChosen: Bool

    public var id: String {
        switch kind {
        case .emoji(let emoji): emoji
        case .customEmoji: "custom"
        case .paid: "paid"
        }
    }
}

/// The quoted message shown above a reply.
public struct ReplyPreview: Equatable, Sendable {
    public let senderName: String
    public let text: String
}

enum MessageMapper {
    /// What the timeline shows for some content; nil for noise Hush leaves out entirely.
    /// - Parameters:
    ///   - senderName: How service lines name the sender ("You" for your own messages).
    ///   - name: Looks up a user's first name, for lines that mention other people.
    static func body(
        for content: MessageContent,
        isOutgoing: Bool,
        senderId: Int64,
        senderName: String,
        name: (Int64) -> String
    ) -> MessageModel.Body? {
        switch content {
        case .messageText(let message):
            return .text(RichText(message.text))
        case .messageAnimatedEmoji(let message):
            return .text(RichText(text: message.emoji))
        case .messageDice(let message):
            return .text(RichText(text: message.emoji))

        // Self-destructing media must disappear after it's viewed, which Telegram's terms require
        // clients to respect. Hush leaves it to your phone rather than risk keeping it around.
        case _ where isSecretMedia(content):
            return selfDestructingPlaceholder
        case .messagePhoto(let message):
            guard let photo = MediaMapping.photo(message.photo) else { return .placeholder("Photo") }
            return .photo(photo, caption: RichText(message.caption))
        case .messageVideo(let message):
            return .video(MediaMapping.video(message.video), caption: RichText(message.caption))
        case .messageAnimation(let message):
            return .video(MediaMapping.animation(message.animation), caption: RichText(message.caption))
        case .messageSticker(let message):
            return .sticker(MediaMapping.sticker(message.sticker))
        case .messageVideoNote(let message):
            return .videoNote(MediaMapping.videoNote(message.videoNote))
        case .messageDocument(let message):
            return .document(MediaMapping.document(message.document), caption: RichText(message.caption))
        case .messageAudio(let message):
            return .document(MediaMapping.audio(message.audio), caption: RichText(message.caption))
        case .messageVoiceNote(let message):
            return .voiceNote(MediaMapping.voiceNote(message.voiceNote, isListened: message.isListened), caption: RichText(message.caption))
        case .messagePoll(let message):
            return .media(label: "Poll: \(message.poll.question.text)", systemImage: "chart.bar", caption: RichText(text: ""))
        case .messageLocation, .messageLiveLocation, .messageVenue:
            return .media(label: "Location", systemImage: "mappin.and.ellipse", caption: RichText(text: ""))
        case .messageContact(let message):
            let contact = [message.contact.firstName, message.contact.lastName].filter { !$0.isEmpty }.joined(separator: " ")
            return .media(label: "Contact: \(contact)", systemImage: "person.crop.circle", caption: RichText(text: ""))

        case .messageStory:
            return .placeholder("Shared a story. Open Telegram on your phone to see it.")
        case .messageGift, .messageUpgradedGift, .messageRefundedUpgradedGift, .messageGiftedPremium,
             .messagePremiumGiftCode, .messageGiftedStars, .messageGiftedGrams:
            return .service("\(senderName) sent a gift")
        case .messageCall(let call):
            let kind = call.isVideo ? "Video call" : "Call"
            if call.duration > 0 {
                return .service("\(kind), \(call.duration / 60):\(String(format: "%02d", call.duration % 60))")
            }
            return .service(isOutgoing ? "\(kind), no answer" : "Missed \(kind.lowercased())")

        case .messageContactRegistered:
            return .service("\(senderName) joined Telegram")
        case .messageBasicGroupChatCreate, .messageSupergroupChatCreate:
            return .service("\(senderName) created the group")
        case .messageChatAddMembers(let message):
            if message.memberUserIds == [senderId] { return .service("\(senderName) joined the group") }
            return .service("\(senderName) added \(names(message.memberUserIds, name))")
        case .messageChatJoinByLink, .messageChatJoinByRequest:
            return .service("\(senderName) joined the group")
        case .messageChatDeleteMember(let message):
            if message.userId == senderId { return .service("\(senderName) left the group") }
            return .service("\(senderName) removed \(name(message.userId))")
        case .messageChatChangeTitle(let message):
            return .service("\(senderName) renamed the group to “\(message.title)”")
        case .messageChatChangePhoto:
            return .service("\(senderName) changed the group photo")
        case .messageChatDeletePhoto:
            return .service("\(senderName) removed the group photo")
        case .messagePinMessage:
            return .service("\(senderName) pinned a message")
        case .messageScreenshotTaken:
            return .service("\(senderName) took a screenshot")
        case .messageChatSetMessageAutoDeleteTime:
            return .service("\(senderName) changed the auto-delete timer")
        case .messageExpiredPhoto, .messageExpiredVideo, .messageExpiredVideoNote, .messageExpiredVoiceNote:
            return .service("Media expired")
        case .messageCustomServiceAction(let message):
            return .service(message.text)
        case .messageVideoChatStarted, .messageVideoChatScheduled:
            return .service("\(senderName) started a voice chat")
        case .messageVideoChatEnded:
            return .service("Voice chat ended")
        case .messageGroupCall(let call):
            return .service(call.wasMissed ? "Missed group call" : "Group call")
        case .messageChecklist(let message):
            return .media(label: "Checklist: \(message.list.title.text)", systemImage: "checklist", caption: RichText(text: ""))

        // Paid posts are a channel feature; Hush doesn't buy content.
        case .messagePaidMedia(let message):
            return .placeholder("Paid content. Open Telegram on your phone to see it." + (message.caption.text.isEmpty ? "" : "\n\(message.caption.text)"))

        // Noise: housekeeping, promotions, payments and mini-app plumbing you don't need to see.
        case .messageChatUpgradeTo, .messageChatUpgradeFrom, .messageChatSetTheme, .messageChatSetBackground,
             .messageChatBoost, .messageGiveawayCreated, .messageGiveaway, .messageGiveawayCompleted,
             .messageGiveawayWinners, .messageGiveawayPrizeStars, .messageUpgradedGiftPurchaseOffer,
             .messageUpgradedGiftPurchaseOfferRejected, .messagePaymentSuccessful, .messagePaymentSuccessfulBot,
             .messagePaymentRefunded, .messagePaidMessagesRefunded, .messagePaidMessagePriceChanged,
             .messageDirectMessagePriceChanged, .messageSuggestedPostApprovalFailed, .messageSuggestedPostApproved,
             .messageSuggestedPostDeclined, .messageSuggestedPostPaid, .messageSuggestedPostRefunded,
             .messageWebAppDataSent, .messageWebAppDataReceived, .messageBotWriteAccessAllowed,
             .messageForumTopicCreated, .messageForumTopicEdited, .messageForumTopicIsClosedToggled,
             .messageForumTopicIsHiddenToggled, .messageChatHasProtectedContentToggled,
             .messageChatHasProtectedContentDisableRequested, .messageChatAddedToCommunity,
             .messageChatRemovedFromCommunity, .messageGameScore:
            return nil

        case .messageUnsupported:
            return .placeholder("This message needs a newer Telegram app. Open it on your phone.")
        default:
            return .placeholder("Hushh can't show this kind of message yet. Open Telegram on your phone to see it.")
        }
    }

    private static func isSecretMedia(_ content: MessageContent) -> Bool {
        switch content {
        case .messagePhoto(let message): message.isSecret
        case .messageVideo(let message): message.isSecret
        case .messageAnimation(let message): message.isSecret
        case .messageVideoNote(let message): message.isSecret
        default: false
        }
    }

    static let selfDestructingPlaceholder = MessageModel.Body.placeholder(
        "Self-destructing media. Open it on your phone, where it can disappear after you've seen it."
    )

    private static func names(_ userIds: [Int64], _ name: (Int64) -> String) -> String {
        let names = userIds.map(name)
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}
