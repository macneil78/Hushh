@preconcurrency import TDLibKit

/// One-line descriptions of messages for the chat list.
enum MessagePreview {
    static func text(for content: MessageContent) -> String {
        let text: String = switch content {
        case .messageText(let message): message.text.text
        case .messagePhoto(let message): labeled("Photo", message.caption)
        case .messageVideo(let message): labeled("Video", message.caption)
        case .messageAnimation(let message): labeled("GIF", message.caption)
        case .messageDocument(let message):
            labeled(message.document.fileName.isEmpty ? "File" : message.document.fileName, message.caption)
        case .messageAudio(let message):
            labeled(message.audio.title.isEmpty ? "Audio" : message.audio.title, message.caption)
        case .messageVoiceNote(let message): labeled("Voice message", message.caption)
        case .messageVideoNote: "Video message"
        case .messageSticker(let message):
            message.sticker.emoji.isEmpty ? "Sticker" : "\(message.sticker.emoji) Sticker"
        case .messageAnimatedEmoji(let message): message.emoji
        case .messageDice(let message): message.emoji
        case .messagePoll(let message): "Poll: \(message.poll.question.text)"
        case .messageLocation, .messageLiveLocation, .messageVenue: "Location"
        case .messageContact(let message):
            "Contact: " + [message.contact.firstName, message.contact.lastName].filter { !$0.isEmpty }.joined(separator: " ")
        case .messageCall(let message): message.isVideo ? "Video call" : "Call"
        case .messageStory: "Story"
        case .messageGift, .messageUpgradedGift, .messageRefundedUpgradedGift, .messageGiftedPremium,
             .messagePremiumGiftCode, .messageGiftedStars, .messageGiftedGrams:
            "Gift"
        case .messageContactRegistered: "Joined Telegram"
        case .messageBasicGroupChatCreate, .messageSupergroupChatCreate: "Created the group"
        case .messageChatAddMembers, .messageChatJoinByLink, .messageChatJoinByRequest: "Joined the group"
        case .messageChatDeleteMember: "Left the group"
        case .messageChatChangeTitle(let message): "Renamed the group to “\(message.title)”"
        case .messageChatChangePhoto: "Changed the group photo"
        case .messagePinMessage: "Pinned a message"
        case .messageCustomServiceAction(let message): message.text
        case .messageExpiredPhoto, .messageExpiredVideo, .messageExpiredVideoNote, .messageExpiredVoiceNote:
            "Expired media"
        default: "Message"
        }
        return singleLine(text)
    }

    /// The text of an unsent draft, flattened to one line, if it has any.
    static func draftText(_ draft: DraftMessage?) -> String? {
        rawDraftText(draft).map(singleLine)
    }

    /// The text of an unsent draft as typed, line breaks included.
    static func rawDraftText(_ draft: DraftMessage?) -> String? {
        guard let draft, case .draftMessageContentText(let content) = draft.content else { return nil }
        return content.text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : content.text.text
    }

    private static func labeled(_ label: String, _ caption: FormattedText) -> String {
        caption.text.isEmpty ? label : "\(label): \(caption.text)"
    }

    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
